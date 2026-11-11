"""Streamed Vietnamese speech calculation backend using MIT faster-whisper.

Receives 16kHz mono PCM over the app's existing WebSocket. Detects end-of-
utterance by measured silence, transcribes on CPU, returns only finalized text.
No spoken audio is persisted, and no paid recognition API is used.
"""
import asyncio,base64,json,time,zlib
from array import array
from pathlib import Path
import numpy as np
from fastapi import FastAPI,WebSocket,WebSocketDisconnect
from faster_whisper import WhisperModel

BASE=Path(__file__).resolve().parent
MODEL=WhisperModel(str(BASE/"models"/"whisper-base"),device="cpu",compute_type="int8",cpu_threads=2,num_workers=1)
app=FastAPI(title="Vietnamese Voice Calculator Whisper STT",docs_url=None,redoc_url=None)
APP_ORIGIN="https://may-tinh-giong-noi-vi.onrender.com"
MAX_SESSION=600
LOCK=asyncio.Lock()
HINT="Số tiền Việt Nam. Mười lăm cộng mười chín cộng mười bảy. Một ngàn, hai ngàn rưỡi, mười hai ngàn, trừ, nhân, chia, phần trăm."

def transcribe(samples):
    if len(samples)<4800:return ""
    segments,info=MODEL.transcribe(samples.astype(np.float32),language="vi",task="transcribe",
        beam_size=3,best_of=2,temperature=0,
        initial_prompt=HINT,condition_on_previous_text=False,
        vad_filter=False,no_speech_threshold=.65,
        repetition_penalty=1.1)
    return " ".join((segment.text or "").strip() for segment in segments).strip()

def decode_pcm(data):
    if len(data)%2: raise ValueError("Invalid PCM length")
    return np.frombuffer(data,dtype="<i2").astype(np.float32)/32768.0

@app.get("/health")
async def health():
    return {"ready":True,"engine":"whisper-base-int8-vi","paid_api":False}

_test_last=0
@app.get("/health/voice")
async def voice_test():
    global _test_last
    if time.monotonic()-_test_last<30:return {"test_ready":False,"reason":"recently tested"}
    if LOCK.locked():return {"test_ready":False,"reason":"busy"}
    _test_last=time.monotonic()
    def work():
        b=zlib.decompress(base64.urlsafe_b64decode((BASE/"test_vietnamese_audio.txt").read_text().strip()))
        sample=np.frombuffer(b,dtype=np.int8).astype(np.float32)/127.0
        audio=np.concatenate((np.zeros(4000,np.float32),sample,np.zeros(6500,np.float32),
          sample,np.zeros(6500,np.float32),sample,np.zeros(10000,np.float32)))
        return {"test_ready":True,"audio_seconds":round(len(audio)/16000,2),
                "transcript":transcribe(audio)}
    try:
        async with LOCK:return await asyncio.wait_for(asyncio.to_thread(work),timeout=50)
    except Exception as exc:return {"test_ready":False,"error_type":type(exc).__name__,"detail":str(exc)[:160]}

@app.websocket("/ws")
async def speech(ws:WebSocket):
    if (ws.headers.get("origin") or "").rstrip("/")!=APP_ORIGIN:
        await ws.close(code=1008);return
    await ws.accept()
    if LOCK.locked():
        await ws.send_json({"type":"error","message":"Bộ nhận giọng nói đang bận. Thử lại sau."})
        await ws.close(code=1013);return
    async with LOCK:
        started=time.monotonic()
        packets=0;received=0;peak=0;last_status=0
        in_speech=False;voice_frames=0
        preroll=[]; utterance=[]
        silence_sec=0; utterance_sec=0
        preceding=None; send_lock=asyncio.Lock()
        alive=True
        async def send(data):
            async with send_lock:await ws.send_json(data)
        async def run_transcription(samples,preceding):
            if preceding:
                try:await preceding
                except Exception:pass
            try:
                result=await asyncio.to_thread(transcribe,samples)
                if result and alive:await send({"type":"final","text":result})
                elif alive:await send({"type":"no-match","message":"Đã nghe âm thanh nhưng không nhận diện được lời nói rõ ràng."})
            except Exception as exc:
                print("WHISPER_DECODE_ERROR",type(exc).__name__,str(exc)[:180],flush=True)
                if alive:await send({"type":"error","message":"Lỗi xử lý giọng nói: "+type(exc).__name__})
        def make_segment():
            nonlocal in_speech,silence_sec,utterance_sec,voice_frames,utterance
            output=np.concatenate(utterance) if utterance else np.array([],dtype=np.float32)
            utterance=[];in_speech=False;silence_sec=0;utterance_sec=0;voice_frames=0
            return output
        def enough_voice():return voice_frames>=4 and utterance_sec>=.45
        try:
            await send({"type":"ready","engine":"whisper-base-int8-vi"})
            print("WHISPER_SESSION_READY",flush=True)
            while True:
                packet=await ws.receive()
                if packet.get("type")=="websocket.disconnect":break
                if time.monotonic()-started>MAX_SESSION:
                    await send({"type":"error","message":"Phiên nghe đã vượt giới hạn thời gian, hãy bấm lại nút micro."})
                    break
                binary=packet.get("bytes")
                if binary is not None:
                    if not binary:continue
                    received+=len(binary);packets+=1
                    if len(binary)>64000 or received>MAX_SESSION*32000 or len(binary)%2:break
                    chunk=decode_pcm(binary)
                    dur=len(chunk)/16000
                    amplitude=float(np.sqrt(np.mean(chunk**2))) if chunk.size else 0
                    peak=max(peak,float(np.max(np.abs(chunk))) if chunk.size else 0)
                    voiced=amplitude>=.008
                    if not in_speech:
                        preroll.append(chunk)
                        # Keep at most about 0.5 seconds preceding first voice.
                        if len(preroll)>6:preroll=preroll[-6:]
                        if voiced:
                            in_speech=True;utterance=preroll.copy();preroll=[]
                            utterance_sec=sum(len(x) for x in utterance)/16000
                            voice_frames=1
                    else:
                        utterance.append(chunk);utterance_sec+=dur
                        if voiced:voice_frames+=1;silence_sec=0
                        else:silence_sec+=dur
                        if silence_sec>=.75 or utterance_sec>=14:
                            valid=enough_voice()
                            segment=make_segment()
                            if valid:
                                preceding=asyncio.create_task(run_transcription(segment,preceding))
                    now=time.monotonic()
                    if now-last_status>=1.5:
                        print("WHISPER_PCM",packets,"packets",received,"bytes",flush=True)
                        await send({"type":"audio-status","seconds":round(received/32000,1),
                            "packets":packets,"level":round(peak*100)})
                        last_status=now;peak=0
                else:
                    try:kind=json.loads(packet.get("text") or "{}").get("type")
                    except Exception:kind=None
                    if kind=="stop":
                        if in_speech:
                            valid=enough_voice();segment=make_segment()
                            if valid:preceding=asyncio.create_task(run_transcription(segment,preceding))
                        if preceding:await preceding
                        await send({"type":"stopped"})
                        break
        except WebSocketDisconnect:pass
        except Exception as exc:
            print("WHISPER_SESSION_ERROR",type(exc).__name__,str(exc)[:200],flush=True)
            try:await send({"type":"error","message":"Lỗi đường truyền: "+type(exc).__name__})
            except Exception:pass
        finally:
            print("WHISPER_SESSION_CLOSED",received,"bytes",packets,"packets",flush=True)
            if preceding and not preceding.done():
                try:await asyncio.wait_for(preceding,timeout=10)
                except Exception:preceding.cancel()
            alive=False
            try:await ws.close()
            except Exception:pass
