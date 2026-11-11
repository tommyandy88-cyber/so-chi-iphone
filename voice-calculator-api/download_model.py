"""Download the permissively licensed multilingual Whisper Base model at build time."""
from pathlib import Path
from faster_whisper.utils import download_model
BASE=Path(__file__).resolve().parent
DEST=BASE/"models"/"whisper-base"
DEST.mkdir(parents=True,exist_ok=True)
folder=download_model("base",output_dir=str(DEST))
if not (DEST/"model.bin").is_file(): raise RuntimeError("Whisper base model download incomplete")
print("WHISPER_MODEL_READY",str(folder),flush=True)
