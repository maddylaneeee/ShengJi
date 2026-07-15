#!/usr/bin/env python3
"""Persistent JSON-lines NLLB translation helper bundled inside 声迹.app."""

import json
import os
import re
import sys
import traceback

import ctranslate2
import sentencepiece as spm


class Runtime:
    def __init__(self):
        self.model_path = None
        self.translator = None
        self.tokenizer = None

    def load(self, model_path):
        model_path = os.path.realpath(model_path)
        if self.model_path == model_path:
            return

        tokenizer_paths = [
            os.path.join(model_path, "sentencepiece.bpe.model"),
            os.path.join(model_path, "flores200_sacrebleu_tokenizer_spm.model"),
        ]
        tokenizer_path = next((path for path in tokenizer_paths if os.path.isfile(path)), None)
        if tokenizer_path is None:
            raise FileNotFoundError("NLLB tokenizer is missing")

        tokenizer = spm.SentencePieceProcessor()
        if not tokenizer.load(tokenizer_path):
            raise RuntimeError("Unable to load the NLLB tokenizer")

        self.translator = ctranslate2.Translator(
            model_path,
            device="cpu",
            compute_type="int8",
            inter_threads=1,
            intra_threads=max(2, min(8, os.cpu_count() or 4)),
        )
        self.tokenizer = tokenizer
        self.model_path = model_path

    def translate(self, request):
        self.load(request["model_path"])
        texts = [text.strip() for text in request.get("texts", [])]
        source_language = request["source_language"]
        target_language = request["target_language"]
        if not texts:
            return []

        groups = [split_preserving_lines(text) for text in texts]
        flattened = [part for group in groups for part in group]
        pieces = self.tokenizer.encode_as_pieces(flattened)
        source = [sentence + ["</s>", source_language] for sentence in pieces]
        prefixes = [[target_language] for _ in source]
        beam_size = max(1, min(8, int(request.get("beam_size", 4))))
        results = self.translator.translate_batch(
            source,
            target_prefix=prefixes,
            beam_size=beam_size,
            max_batch_size=512,
            batch_type="tokens",
            max_decoding_length=256,
            repetition_penalty=1.08,
        )
        hypotheses = []
        for result in results:
            tokens = list(result.hypotheses[0])
            if tokens and tokens[0] == target_language:
                tokens = tokens[1:]
            hypotheses.append(tokens)
        decoded = self.tokenizer.decode(hypotheses)
        output = []
        cursor = 0
        for group in groups:
            translated_parts = decoded[cursor : cursor + len(group)]
            cursor += len(group)
            output.append(rebuild_preserving_lines(group, translated_parts, target_language))
        return output


def split_preserving_lines(text):
    lines = text.split("\n")
    parts = []
    for line_index, line in enumerate(lines):
        chunks = split_for_translation(line)
        parts.extend(chunks)
        if line_index != len(lines) - 1:
            parts.append("\n")
    return parts or [""]


def rebuild_preserving_lines(source_parts, translated_parts, target_language):
    output = []
    current_line = []
    for source, translated in zip(source_parts, translated_parts):
        if source == "\n":
            output.append(clean_translation(" ".join(current_line), target_language))
            current_line = []
        else:
            current_line.append(translated)
    output.append(clean_translation(" ".join(current_line), target_language))
    return "\n".join(output)


def split_for_translation(text, limit=420):
    text = re.sub(r"[\t\r\f\v ]+", " ", text).strip()
    if len(text) <= limit:
        return [text]
    sentences = re.split(r"(?<=[。！？!?；;．\.])\s*", text)
    chunks = []
    current = ""
    for sentence in sentences:
        if not sentence:
            continue
        while len(sentence) > limit:
            if current:
                chunks.append(current)
                current = ""
            chunks.append(sentence[:limit])
            sentence = sentence[limit:]
        if len(current) + len(sentence) <= limit:
            current += sentence
        else:
            if current:
                chunks.append(current)
            current = sentence
    if current:
        chunks.append(current)
    return chunks or [text]


def clean_translation(text, target_language):
    text = text.replace("<unk>", " ⁇ ")
    text = re.sub(r"(?<=\s)\?\?(?=\s)", " ⁇ ", text)
    text = re.sub(r"\s+([,.;:!?，。；：！？])", r"\1", text)
    text = re.sub(r"\s+", " ", text).strip()
    if target_language in ("zho_Hans", "zho_Hant"):
        text = re.sub(r"秘\s*⁇", "秘密", text)
        text = re.sub(r"⁇\s*瓜", "傻瓜", text)
        text = text.replace("⁇", " ")
        text = re.sub(r"(?<=[\u3400-\u9fff])\s+(?=[\u3400-\u9fff])", "", text)
        text = text.replace(",", "，").replace(";", "；").replace(":", "：")
        text = re.sub(r"(?<!\d)\.(?!\d)", "。", text)
        text = re.sub(r"(?<!\?)\?(?!\?)", "？", text)
        text = text.replace("!", "！")
    else:
        text = text.replace("⁇", " ")
    text = re.sub(r"\s+", " ", text).strip()
    return text


def respond(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    runtime = Runtime()
    respond({"ok": True, "ready": True, "runtime": ctranslate2.__version__})
    for line in sys.stdin:
        try:
            request = json.loads(line)
            command = request.get("command", "translate")
            if command == "shutdown":
                respond({"ok": True})
                return
            if command == "health":
                respond({"ok": True, "ready": True, "runtime": ctranslate2.__version__})
                continue
            translations = runtime.translate(request)
            unit_ids = request.get("unit_ids")
            payload = {"ok": True, "translations": translations}
            if isinstance(unit_ids, list) and len(unit_ids) == len(translations):
                payload["results"] = [
                    {"id": unit_id, "text": translation}
                    for unit_id, translation in zip(unit_ids, translations)
                ]
            respond(payload)
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            respond({"ok": False, "error": str(error)})


if __name__ == "__main__":
    main()
