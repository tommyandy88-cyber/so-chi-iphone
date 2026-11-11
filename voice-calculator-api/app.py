"""Free speech-to-text backend for the large microphone button.
Streaming mono 16 kHz signed PCM via WebSocket, local Vosk Vietnamese model.
No paid API, no recording or storage. Does NOT change the calculator math.
"""
import asyncio
import json
import os
import time
from pathlib import Path
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from vosk import Model, KaldiRecognizer, SetLogLevel

SetLogLevel(-1)
MODEL_DIR=Path(__file__).resolve().parent/"model"/"vosk-model-small-vn-0.4"
model=Model(str(MODEL_DIR))
app=FastAPI(title="Voice Calculator Free Speech Service",docs_url=None,redoc_url=None)
APP_ORIGIN="https://may-tinh-giong-noi-vi.onrender.com"
MAX_SECONDS=12*60
MAX_AUDIO_BYTES=16000*2*MAX_SECONDS

@app.get("/health")
async def health():
    return {"ready": True,"engine":"vosk-small-vn","cost":"no paid speech API"}

@app.websocket("/ws")
async def recognize(ws: WebSocket):
    origin=(ws.headers.get("origin") or "").rstrip("/")
    if origin!=APP_ORIGIN:
        await ws.close(code=1008,reason="Origin not allowed")
        return
    await ws.accept()
    try:
        rec=KaldiRecognizer(model,16000)
        rec.SetWords(False)
        await ws.send_json({"type":"ready","engine":"vosk"})
        bytes_seen=0
        started=time.monotonic()
        while True:
            msg=await ws.receive()
            if msg.get("type")=="websocket.disconnect": break
            if time.monotonic()-started>MAX_SECONDS: 
                await ws.send_json({"type":"error","message":"Đã đạt giới hạn thời gian phiên nghe. Hãy chạm micro để bắt đầu lại."})
                break
            binary=msg.get("bytes")
            if binary is not None:
                if not binary: continue
                bytes_seen+=len(binary)
                if len(binary)>64000 or bytes_seen>MAX_AUDIO_BYTES:
                    await ws.send_json({"type":"error","message":"Phiên thu âm đã vượt giới hạn."})
                    break
                if rec.AcceptWaveform(binary):
                    result=json.loads(rec.Result())
                    spoken=(result.get("text") or "").strip()
                    if spoken: await ws.send_json({"type":"final","text":spoken})
                else:
                    p=json.loads(rec.PartialResult()).get("partial","").strip()
                    if p: await ws.send_json({"type":"partial","text":p})
            else:
                try: command=json.loads(msg.get("text") or "{}").get("type")
                except (TypeError,ValueError):command=None
                if command=="stop":
                    final=json.loads(rec.FinalResult()).get("text","").strip()
                    if final: await ws.send_json({"type":"final","text":final})
                    await ws.send_json({"type":"stopped"})
                    break
    except WebSocketDisconnect:
        pass
    except Exception:
        try: await ws.send_json({"type":"error","message":"Bộ nhận dạng giọng nói gặp lỗi."})
        except Exception:pass
    finally:
        try: await ws.close()
        except Exception:pass
