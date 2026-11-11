"""Vietnamese voice recognition backend (Moonshine Vietnamese Streaming).

Protocol stays unchanged for the existing iPhone large-microphone frontend:
  WebSocket /ws, binary signed 16-bit mono PCM 16 kHz.
  {"type":"ready"}, {"type":"partial","text":...}, {"type":"final","text":...}
  Client sends {"type":"stop"} to flush the final utterance.
No OpenAI API, cloud transcription provider, recording persistence or key.
"""
import asyncio
from array import array
import json
import os
from pathlib import Path
import time

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

BASE=Path(__file__).resolve().parent
os.environ.setdefault("MOONSHINE_VOICE_CACHE",str(BASE/"models"))
from moonshine_voice import Transcriber, TranscriptEventListener, get_model_for_language

MODEL_PATH, MODEL_ARCH = get_model_for_language("vi")
app=FastAPI(title="Vietnamese Calculator Voice Backend",docs_url=None,redoc_url=None)

APP_ORIGIN="https://may-tinh-giong-noi-vi.onrender.com"
LIMIT_SECONDS=10*60
MAX_TOTAL_AUDIO=16000*2*LIMIT_SECONDS
active_session=asyncio.Lock()

@app.get("/health")
async def health():
    return {"ready": True, "engine": "moonshine-tiny-streaming-vi",
            "model_loaded":Path(MODEL_PATH).exists(),
            "paid_api":False}

def pcm_to_float(chunk: bytes) -> list[float]:
    # Audio is mono 16 kHz little-endian signed 16-bit PCM.
    if len(chunk)%2: raise ValueError("Odd PCM byte count")
    buf=array("h")
    buf.frombytes(chunk)
    import sys
    if sys.byteorder=="big": buf.byteswap()
    return [sample/32768.0 for sample in buf]

# Diagnostic test of the native speech pipeline without storing any audio.
# Used to distinguish a ready web server from a working transcriber.
_last_probe=0.0
@app.get("/health/stream")
async def stream_probe():
    global _last_probe
    now=time.monotonic()
    if now-_last_probe<30:
        return {"stream_ok":False,"message":"Diagnostic recently run"}
    if active_session.locked():
        return {"stream_ok":False,"message":"Speech server busy"}
    _last_probe=now
    def work():
        t=Transcriber(model_path=str(MODEL_PATH),model_arch=MODEL_ARCH)
        st=None
        try:
            st=t
            st.start()
            st.add_audio([0.0]*8000,16000)
            st.stop()
            return {"stream_ok":True,"engine":"moonshine-tiny-streaming-vi"}
        finally:
            if st:
                try:st.close()
                except Exception:pass
            try:t.close()
            except Exception:pass
    try:
        async with active_session:
            return await asyncio.wait_for(asyncio.to_thread(work),timeout=25)
    except Exception as exc:
        return {"stream_ok":False,"error_type":type(exc).__name__}

# Synthetic spoken-word test; never uses user audio or saves recordings.
_test_last_time=0
@app.get("/health/voice")
async def test_vietnamese_speech():
    global _test_last_time
    now=time.monotonic()
    if now-_test_last_time<20:
        return {"test_ready":False,"reason":"throttled"}
    if active_session.locked():
        return {"test_ready":False,"reason":"busy"}
    _test_last_time=now
    def run():
        import base64,zlib
        encoded=(BASE/"test_vietnamese_audio.txt").read_text().strip()
        raw=zlib.decompress(base64.urlsafe_b64decode(encoded))
        # The test audio was synthesized using the Vietnamese espeak voice,
        # then quantized to 8-bit PCM for a tiny non-sensitive test artifact.
        import numpy as np
        samples=np.frombuffer(raw,dtype=np.int8).astype(np.float32)/127.0
        # Include silence before/after so voice activity boundaries can resolve.
        samples=np.concatenate((np.zeros(4800,dtype=np.float32),samples,np.zeros(16000,dtype=np.float32)))
        observed=[]
        class ProbeListener(TranscriptEventListener):
            def on_line_text_changed(self,event):
                value=str(event.line.text or "").strip()
                if value:observed.append({"kind":"partial","text":value})
            def on_line_completed(self,event):
                value=str(event.line.text or "").strip()
                if value:observed.append({"kind":"final","text":value})
        t=Transcriber(model_path=str(MODEL_PATH),model_arch=MODEL_ARCH)
        try:
            listener=ProbeListener();t.add_listener(listener)
            t.start()
            for i in range(0,len(samples),1600):
                t.add_audio(samples[i:i+1600].tolist(),16000)
            t.stop()
            return {"test_ready":True,"audio_seconds":round(len(samples)/16000,2),
                    "events":observed[-10:],
                    "event_count":len(observed)}
        finally:t.close()
    try:
        async with active_session:
            return await asyncio.wait_for(asyncio.to_thread(run),timeout=45)
    except Exception as exc:
        return {"test_ready":False,"error_type":type(exc).__name__,"error":str(exc)[:180]}

@app.websocket("/ws")
async def receive_audio(ws: WebSocket):
    origin=(ws.headers.get("origin") or "").rstrip("/")
    if origin!=APP_ORIGIN:
        await ws.close(code=1008,reason="Origin not allowed")
        return
    await ws.accept()
    if active_session.locked():
        await ws.send_json({"type":"error","message":"Bộ nhận giọng nói đang được sử dụng. Hãy thử lại sau."})
        await ws.close(code=1013)
        return

    async with active_session:
        # Sending model ready only after all model weights and stream are open
        # prevents the browser from sending audio before it can be processed.
        loop=asyncio.get_running_loop()
        queue=asyncio.Queue(maxsize=160)
        transcriber=None
        stream=None
        send_task=None
        started=time.monotonic()
        total_bytes=0
        audio_packets=0
        audio_peak=0.0
        last_audio_status=0.0
        last_partial=0.0

        def enqueue(message):
            def push():
                if queue.full() and message.get("type")=="partial": return
                try: queue.put_nowait(message)
                except asyncio.QueueFull: pass
            try:loop.call_soon_threadsafe(push)
            except RuntimeError:pass

        class Listener(TranscriptEventListener):
            def on_line_text_changed(self,event):
                nonlocal last_partial
                value=str(event.line.text or "").strip()
                now=time.monotonic()
                if value and now-last_partial>=.20:
                    last_partial=now
                    enqueue({"type":"partial","text":value})
            def on_line_completed(self,event):
                value=str(event.line.text or "").strip()
                if value:enqueue({"type":"final","text":value})
            def on_error(self,event):
                enqueue({"type":"error","message":"Bộ nhận dạng gặp lỗi trong phiên nghe."})

        async def send_results():
            while True:
                item=await queue.get()
                try:
                    if item is None: break
                    await ws.send_json(item)
                except Exception:
                    break
                finally:
                    queue.task_done()

        try:
            transcriber=await asyncio.to_thread(
                Transcriber,model_path=str(MODEL_PATH),model_arch=MODEL_ARCH)
            # Use the documented one-input Transcriber API, rather than the
            # multi-stream API; callbacks belong to the transcriber itself.
            listener=Listener()
            transcriber.add_listener(listener)
            await asyncio.to_thread(transcriber.start)
            send_task=asyncio.create_task(send_results())
            print("VOICE_SESSION_READY",flush=True)
            await ws.send_json({"type":"ready","engine":"moonshine-tiny-streaming-vi"})
            while True:
                packet=await ws.receive()
                if packet.get("type")=="websocket.disconnect":break
                if time.monotonic()-started>LIMIT_SECONDS:
                    enqueue({"type":"error","message":"Phiên nghe đã đạt giới hạn thời gian. Hãy chạm lại nút micro."})
                    break
                data=packet.get("bytes")
                if data is not None:
                    if not data: continue
                    total_bytes+=len(data)
                    if len(data)>64000 or total_bytes>MAX_TOTAL_AUDIO or len(data)%2:
                        enqueue({"type":"error","message":"Luồng âm thanh không hợp lệ hoặc vượt giới hạn."})
                        break
                    # moonshine_voice processes incremental 32-bit floating point PCM.
                    samples=pcm_to_float(data)
                    audio_packets+=1
                    audio_peak=max(audio_peak,max((abs(sample) for sample in samples),default=0.0))
                    now=time.monotonic()
                    if now-last_audio_status>=1.5:
                        print("VOICE_PCM",audio_packets,"packets",total_bytes,"bytes",flush=True)
                        enqueue({"type":"audio-status",
                                 "seconds":round(total_bytes/32000,1),
                                 "packets":audio_packets,
                                 "level":round(audio_peak*100)})
                        last_audio_status=now
                        audio_peak=0.0
                    await asyncio.to_thread(transcriber.add_audio,samples,16000)
                else:
                    try: kind=json.loads(packet.get("text") or "{}").get("type")
                    except (TypeError,ValueError):kind=None
                    if kind=="stop":
                        await asyncio.to_thread(transcriber.stop)
                        # Native event callbacks can arrive on a worker thread.
                        await asyncio.sleep(.12)
                        enqueue({"type":"stopped"})
                        await asyncio.wait_for(queue.join(),timeout=4)
                        break
        except WebSocketDisconnect:
            pass
        except Exception as exc:
            print("VOICE_SESSION_ERROR",type(exc).__name__,str(exc)[:200],flush=True)
            message={"type":"error","message":"Nhận dạng giọng nói bị gián đoạn: "+type(exc).__name__}
            if send_task:
                enqueue(message)
            else:
                try: await ws.send_json(message)
                except Exception: pass
        finally:
            if transcriber:
                print("VOICE_SESSION_CLOSED",total_bytes,"audio-bytes",audio_packets,"packets",flush=True)
                try:await asyncio.to_thread(transcriber.stop)
                except Exception:pass
            if transcriber:
                try:await asyncio.to_thread(transcriber.close)
                except Exception:pass
            if send_task:
                try:
                    await asyncio.wait_for(queue.join(),timeout=2)
                except Exception:pass
                try:queue.put_nowait(None)
                except asyncio.QueueFull:pass
                try:await asyncio.wait_for(send_task,timeout=2)
                except Exception:send_task.cancel()
            try:await ws.close()
            except Exception:pass
