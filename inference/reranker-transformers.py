#!/usr/bin/env python3
"""
Native Weaviate reranker-transformers inference service.
Drop-in replacement for cr.weaviate.io/semitechnologies/reranker-transformers.

API: POST /rerank {query, documents[]} → {query, scores[{document, score}]}
     POST /rerank {query, property} → {query, property, score}
     GET /.well-known/live → 204
     GET /.well-known/ready → 204
     GET /meta → model info

NOTE: This service is created by ProxLab Helper Scripts and is NOT made by
or associated with Weaviate or SeMI Technologies.
"""

import os
import logging
from contextlib import asynccontextmanager
from typing import Optional

import torch
import uvicorn
from fastapi import FastAPI, Response
from pydantic import BaseModel, Field
from sentence_transformers import CrossEncoder

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("reranker-transformers")

MODEL_NAME = os.environ.get("MODEL_NAME", "cross-encoder/ms-marco-MiniLM-L-6-v2")
MODEL_PATH = os.environ.get("MODEL_PATH", "./models/model")
PORT = int(os.environ.get("PORT", "8080"))
ENABLE_CUDA = os.environ.get("ENABLE_CUDA", "0") == "1"

model: CrossEncoder = None


class RerankRequest(BaseModel):
    query: str
    documents: Optional[list[str]] = None
    property: Optional[str] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global model
    device = "cuda" if ENABLE_CUDA and torch.cuda.is_available() else "cpu"
    log.info(f"Loading reranker model: {MODEL_NAME} on {device}")

    if os.path.isdir(MODEL_PATH):
        model = CrossEncoder(MODEL_PATH, device=device)
        log.info(f"Loaded model from cache: {MODEL_PATH}")
    else:
        model = CrossEncoder(MODEL_NAME, device=device)
        os.makedirs(MODEL_PATH, exist_ok=True)
        model.save_pretrained(MODEL_PATH)
        log.info(f"Downloaded and cached model to {MODEL_PATH}")

    log.info("Reranker model ready")
    yield
    log.info("Shutting down")


app = FastAPI(lifespan=lifespan)


@app.get("/.well-known/live", status_code=204)
async def live():
    return Response(status_code=204)


@app.get("/.well-known/ready", status_code=204)
async def ready():
    if model is None:
        return Response(status_code=503)
    return Response(status_code=204)


@app.get("/meta")
async def meta():
    return {
        "model": MODEL_NAME,
        "type": "cross-encoder",
    }


@app.post("/rerank")
async def rerank(req: RerankRequest):
    try:
        # Mode 1: Batch rerank — documents list provided
        if req.documents is not None:
            pairs = [[req.query, doc] for doc in req.documents]
            scores = model.predict(pairs).tolist()
            return {
                "query": req.query,
                "scores": [
                    {"document": doc, "score": float(score)}
                    for doc, score in zip(req.documents, scores)
                ],
            }

        # Mode 2: Single pair — property provided
        if req.property is not None:
            score = model.predict([[req.query, req.property]]).tolist()[0]
            return {
                "query": req.query,
                "property": req.property,
                "score": float(score),
            }

        return Response(
            content='{"error": "Either documents or property must be provided"}',
            status_code=400,
            media_type="application/json",
        )
    except Exception as e:
        log.error(f"Rerank error: {e}")
        return Response(content=f'{{"error": "{e}"}}', status_code=500, media_type="application/json")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
