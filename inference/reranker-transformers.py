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
import json
import logging
from contextlib import asynccontextmanager

import torch
import uvicorn
from fastapi import FastAPI, Response, Request

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("reranker-transformers")

MODEL_NAME = os.environ.get("MODEL_NAME", "cross-encoder/ms-marco-MiniLM-L-6-v2")
MODEL_PATH = os.environ.get("MODEL_PATH", "./models/model")
PORT = int(os.environ.get("PORT", "8080"))
ENABLE_CUDA = os.environ.get("ENABLE_CUDA", "0") == "1"

model = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global model
    from sentence_transformers import CrossEncoder

    device = "cuda" if ENABLE_CUDA and torch.cuda.is_available() else "cpu"
    log.info(f"Loading reranker model: {MODEL_NAME} on {device}")
    model = CrossEncoder(MODEL_PATH if os.path.isdir(MODEL_PATH) else MODEL_NAME, device=device)
    if not os.path.isdir(MODEL_PATH):
        os.makedirs(MODEL_PATH, exist_ok=True)
        model.save_pretrained(MODEL_PATH)
    log.info("Reranker model ready")
    yield
    log.info("Shutting down")


app = FastAPI(lifespan=lifespan)


@app.get("/.well-known/live", status_code=204)
@app.get("/.well-known/ready", status_code=204)
async def health():
    return Response(status_code=204 if model else 503)


@app.get("/meta")
async def meta():
    return {"model": MODEL_NAME, "type": "cross-encoder"}


@app.post("/rerank")
async def rerank(request: Request):
    try:
        body = await request.json()
        query = body.get("query", "")
        documents = body.get("documents")
        prop = body.get("property")

        if documents is not None:
            pairs = [[query, doc] for doc in documents]
            scores = model.predict(pairs).tolist()
            return {
                "query": query,
                "scores": [
                    {"document": doc, "score": float(score)}
                    for doc, score in zip(documents, scores)
                ],
            }

        if prop is not None:
            score = model.predict([[query, prop]]).tolist()[0]
            return {"query": query, "property": prop, "score": float(score)}

        return Response(
            content='{"error": "Either documents or property must be provided"}',
            status_code=400,
            media_type="application/json",
        )
    except Exception as e:
        log.error(f"Rerank error: {e}")
        return Response(content=json.dumps({"error": str(e)}), status_code=500, media_type="application/json")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
