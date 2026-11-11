#!/usr/bin/env python3
"""Generate the non-signed Apple Shortcut; GitHub macOS runner signs it.
This uses Apple's native Dictate Text action, not a paid speech model.
"""
from pathlib import Path
import plistlib
import uuid

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "out"
OUT.mkdir(exist_ok=True)

def new_id():
    return str(uuid.uuid4()).upper()

def output_ref(source, output):
    return {
        "WFSerializationType": "WFTextTokenAttachment",
        "Value": {"Type": "ActionOutput", "OutputUUID": source, "OutputName": output},
    }

def text_with_ref(prefix, source, output):
    return {
        "WFSerializationType": "WFTextTokenString",
        "Value": {
            "string": prefix + "\uFFFC",
            "attachmentsByRange": {
                "{%d, 1}" % len(prefix): {
                    "Type": "ActionOutput", "OutputUUID": source, "OutputName": output
                }
            },
        },
    }

dictated = new_id()
encoded = new_id()
url_id = new_id()
url = "https://may-tinh-giong-noi-vi.onrender.com/?source=apple-shortcuts&dictation="

actions = [
    {
        "WFWorkflowActionIdentifier": "is.workflow.actions.dictatetext",
        "WFWorkflowActionParameters": {
            "UUID": dictated,
            "WFSpeechLanguage": "vi-VN",
            # The user can read a long sequence, tapping Done once at the end.
            "WFDictateTextStopListening": "On Tap",
        },
    },
    {
        "WFWorkflowActionIdentifier": "is.workflow.actions.urlencode",
        "WFWorkflowActionParameters": {
            "UUID": encoded,
            "WFEncodeMode": "Encode",
            "WFInput": output_ref(dictated, "Dictated Text"),
        },
    },
    {
        "WFWorkflowActionIdentifier": "is.workflow.actions.url",
        "WFWorkflowActionParameters": {
            "UUID": url_id,
            "WFURLActionURL": text_with_ref(url, encoded, "URL Encoded Text"),
        },
    },
    {
        "WFWorkflowActionIdentifier": "is.workflow.actions.openurl",
        "WFWorkflowActionParameters": {"WFInput": output_ref(url_id, "URL")},
    },
]

shortcut = {
    "WFWorkflowName": "Kanaan Voice Calc",
    "WFWorkflowActions": actions,
    "WFWorkflowClientVersion": "1302.1.3",
    "WFWorkflowClientRelease": "18.0",
    "WFWorkflowMinimumClientVersion": 1300,
    "WFWorkflowMinimumClientVersionString": "1300",
    "WFWorkflowIcon": {
        "WFWorkflowIconStartColor": 4282601983,
        "WFWorkflowIconGlyphNumber": 59565,
    },
    "WFWorkflowImportQuestions": [],
    "WFWorkflowInputContentItemClasses": [],
    "WFWorkflowOutputContentItemClasses": [],
    "WFWorkflowTypes": [],
    "WFWorkflowHasOutputFallback": False,
    "WFWorkflowHasShortcutInputVariables": False,
}

outpath = OUT / "Kanaan-Voice-Calc.unsigned.shortcut"
with outpath.open("wb") as stream:
    plistlib.dump(shortcut, stream, fmt=plistlib.FMT_BINARY)
with outpath.open("rb") as stream:
    decoded = plistlib.load(stream)
assert len(decoded["WFWorkflowActions"]) == 4
assert decoded["WFWorkflowActions"][0]["WFWorkflowActionParameters"]["WFSpeechLanguage"] == "vi-VN"
print(f"Created and verified {outpath} ({outpath.stat().st_size} bytes)")
