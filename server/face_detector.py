#!/usr/bin/env python3
"""Extract one representative crop and SFace embedding for each detected face."""

import json
import os
import sys

os.environ.setdefault("OPENCV_IO_MAX_IMAGE_PIXELS", "20000000")
import cv2
import numpy as np


def main():
    cv2.setNumThreads(1)
    source, kind, output = sys.argv[1:4]
    models = os.environ.get("FACE_MODEL_DIR", os.path.dirname(__file__))
    detector = cv2.FaceDetectorYN.create(
        os.path.join(models, "face_detection_yunet_2023mar.onnx"), "", (320, 320), 0.8, 0.3
    )
    recognizer = cv2.FaceRecognizerSF.create(
        os.path.join(models, "face_recognition_sface_2021dec.onnx"), ""
    )
    if kind == "photo":
        frame = cv2.imread(source)
    else:
        video = cv2.VideoCapture(source)
        frame = None
        if video.isOpened():
            for _ in range(6):
                ok, candidate = video.read()
                if not ok:
                    break
                frame = candidate
        video.release()
    if frame is None:
        print("[]")
        return

    height, width = frame.shape[:2]
    if max(height, width) > 1600:
        scale = 1600 / max(height, width)
        frame = cv2.resize(
            frame, (round(width * scale), round(height * scale)), interpolation=cv2.INTER_AREA
        )
        height, width = frame.shape[:2]
    try:
        detector.setInputSize((width, height))
        _, faces = detector.detect(frame)
    except cv2.error:
        print("[]")
        return
    results = []
    for index, face in enumerate([] if faces is None else faces[:12]):
        x, y, w, h = face[:4]
        if w < 24 or h < 24:
            continue
        try:
            aligned = recognizer.alignCrop(frame, face)
            feature = recognizer.feature(aligned).flatten().astype(np.float64)
        except cv2.error:
            continue
        norm = np.linalg.norm(feature)
        if not np.isfinite(norm) or norm == 0:
            continue
        feature /= norm
        side = max(w, h) * 1.4
        cx, cy = x + w / 2, y + h / 2
        left, top = max(0, int(cx - side / 2)), max(0, int(cy - side / 2))
        right, bottom = min(width, int(cx + side / 2)), min(height, int(cy + side / 2))
        crop = frame[top:bottom, left:right]
        if crop.size == 0:
            continue
        crop = cv2.resize(crop, (160, 160), interpolation=cv2.INTER_AREA)
        path = os.path.join(output, f"{index}.jpg")
        if not cv2.imwrite(path, crop, [cv2.IMWRITE_JPEG_QUALITY, 75]):
            continue
        results.append({"file": path, "feature": feature.tolist()})
    print(json.dumps(results))


if __name__ == "__main__":
    main()
