"""
RAG 检索服务 —— 为 MATLAB 反算框架提供知识检索

启动方式:
    cd knowledge_base/rag_service
    pip install -r requirements.txt
    python rag_server.py

MATLAB 调用示例:
    query = struct('query', '水泥稳定碎石基层 半刚性路面 25°C', 'top_k', 3);
    response = webwrite('http://localhost:8000/retrieve', query);
    % response.knowledge 是检索到的条文列表，每条含 content + source

设计原则:
    - 轻量: ChromaDB 本地文件存储，零依赖数据库
    - 可追溯: 每条知识返回时带 source 出处
    - 可复现: 审稿人 pip install 后即可运行
"""

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import chromadb
import json
import os

app = FastAPI(title="iLLM-PMB Knowledge RAG", version="1.0")

# ====== 配置 ======
KB_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSONL_PATH = os.path.join(KB_DIR, "knowledge_base.jsonl")
CHROMA_PATH = os.path.join(KB_DIR, "chroma_db")

# ====== 初始化 ChromaDB ======
chroma_client = chromadb.PersistentClient(path=CHROMA_PATH)

# 使用 Ollama bge-m3（本地 embedding）
from chromadb.utils import embedding_functions
try:
    # 优先用 Ollama embedding
    ollama_ef = embedding_functions.OllamaEmbeddingFunction(
        model_name="bge-m3",
        url="http://localhost:11434/api/embeddings",
    )
    print("[OK] Ollama bge-m3 embedding ready")
except Exception:
    # 回退到 sentence-transformers（需要 pip install sentence-transformers）
    print("[WARN] Ollama not available, falling back to sentence-transformers")
    ollama_ef = embedding_functions.SentenceTransformerEmbeddingFunction(
        model_name="BAAI/bge-m3"
    )


# ====== Pydantic models ======
class QueryRequest(BaseModel):
    query: str
    top_k: int = 3


class KnowledgeItem(BaseModel):
    id: str
    content: str
    source: str
    tags: list[str]
    type: str


class QueryResponse(BaseModel):
    query: str
    knowledge: list[KnowledgeItem]


# ====== 加载/重建索引 ======
def load_or_build_index():
    """加载已有索引，或从 JSONL 重新构建"""
    collection_name = "pavement_knowledge"

    # 如果索引已存在，直接返回
    existing = chroma_client.list_collections()
    existing_names = [c.name for c in existing]
    if collection_name in existing_names:
        print(f"[OK] Loaded existing index: {collection_name}")
        return chroma_client.get_collection(
            name=collection_name,
            embedding_function=ollama_ef,
        )

    # 否则从 JSONL 构建
    print(f"[BUILD] Building index from {JSONL_PATH}...")
    collection = chroma_client.create_collection(
        name=collection_name,
        embedding_function=ollama_ef,
        metadata={"description": "Pavement engineering knowledge for FWD backcalculation"},
    )

    with open(JSONL_PATH, "r", encoding="utf-8") as f:
        documents = [json.loads(line) for line in f if line.strip()]

    collection.add(
        ids=[doc["id"] for doc in documents],
        documents=[doc["content"] for doc in documents],
        metadatas=[
            {
                "source": doc["source"],
                "tags": ",".join(doc["tags"]),
                "type": doc["type"],
            }
            for doc in documents
        ],
    )

    print(f"[OK] Indexed {len(documents)} documents")
    return collection


collection = load_or_build_index()


# ====== 检索接口 ======
@app.post("/retrieve", response_model=QueryResponse)
def retrieve(request: QueryRequest):
    """检索与查询最相关的规范知识"""
    results = collection.query(
        query_texts=[request.query],
        n_results=request.top_k,
    )

    knowledge = []
    if results["ids"] and results["ids"][0]:
        for i in range(len(results["ids"][0])):
            meta = results["metadatas"][0][i]
            knowledge.append(KnowledgeItem(
                id=results["ids"][0][i],
                content=results["documents"][0][i],
                source=meta.get("source", ""),
                tags=meta.get("tags", "").split(",") if meta.get("tags") else [],
                type=meta.get("type", "rag"),
            ))

    return QueryResponse(query=request.query, knowledge=knowledge)


@app.get("/health")
def health():
    return {"status": "ok", "doc_count": collection.count()}


@app.post("/rebuild")
def rebuild_index():
    """重建索引（新增知识片段后调用）"""
    global collection
    collection_name = "pavement_knowledge"
    try:
        chroma_client.delete_collection(collection_name)
    except Exception:
        pass
    collection = load_or_build_index()
    return {"status": "rebuilt", "doc_count": collection.count()}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)
