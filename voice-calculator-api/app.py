"""Vietnamese voice recognition backend (Moonshine Tiny Streaming, MIT).

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
            stream=transcriber.create_stream(update_interval=.25)
            stream.add_listener(Listener())
            await asyncio.to_thread(stream.start)
            send_task=asyncio.create_task(send_results())
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
                    await asyncio.to_thread(stream.add_audio,samples,16000)
                else:
                    try: kind=json.loads(packet.get("text") or "{}").get("type")
                    except (TypeError,ValueError):kind=None
                    if kind=="stop":
                        await asyncio.to_thread(stream.stop)
                        # Native event callbacks can arrive on a worker thread.
                        await asyncio.sleep(.12)
                        enqueue({"type":"stopped"})
                        await asyncio.wait_for(queue.join(),timeout=4)
                        break
        except WebSocketDisconnect:
            pass
        except Exception as exc:
            enqueue({"type":"error","message":"Nhận dạng giọng nói bị gián đoạn: "+type(exc).__name__})
        finally:
            if stream:
                try:await asyncio.to_thread(stream.stop)
                except Exception:pass
                try:await asyncio.to_thread(stream.close)
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
