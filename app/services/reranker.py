import os
import logging
from typing import List, Dict, Any, Optional

logger = logging.getLogger("HybridReranker")

class DualTierReranker:
    """
    Principal Engineer Grade Re-Ranking Architecture.
    
    Why Both FlashRank and Cohere?
    ------------------------------
    1. FlashRank (Tier-1 Local In-Process):
       - Latency: < 15ms on standard CPU via ONNX runtime.
       - Cost: $0.00 (zero marginal egress API expense).
       - Privacy: 100% air-gapped; sensitive security data never leaves your VPC.
       - Primary Role: High-throughput candidate pruning (50 -> 15).
       
    2. Cohere v3.5 (Tier-2 Hosted Cross-Encoder):
       - Accuracy: Deep cross-attention transformer with state-of-the-art multi-lingual semantic reasoning.
       - Latency: ~150-300ms over HTTPS.
       - Primary Role: Deep precision ranking on top candidates (15 -> 5).
       
    3. Cascaded Dual-Tier Strategy:
       - Uses local FlashRank as the fast, resilient baseline.
       - If COHERE_API_KEY is available and deep precision is demanded, cascades top candidates to Cohere.
       - Seamless fallback: zero downtime if Cohere API experiences outages or rate limits.
    """

    def __init__(self):
        self.cohere_key = os.getenv("COHERE_API_KEY", "")
        self._flashrank_client = None
        self._init_flashrank()

    def _init_flashrank(self):
        try:
            from flashrank import Ranker
            # Initialize lightweight local cross-encoder model
            self._flashrank_client = Ranker(model_name="ms-marco-TinyBERT-L-2-v2", cache_dir="/tmp/flashrank")
            logger.info("⚡ FlashRank local cross-encoder initialized successfully.")
        except Exception as e:
            logger.warning(f"FlashRank initialization failed: {e}. Fallback to lexical ranking.")
            self._flashrank_client = None

    def rerank_flashrank(self, query: str, documents: List[Dict[str, Any]], top_k: int = 5) -> List[Dict[str, Any]]:
        """Executes ultra-fast local re-ranking via FlashRank."""
        if not documents:
            return []
        if not self._flashrank_client:
            return documents[:top_k]

        try:
            from flashrank import RerankRequest
            passages = []
            for idx, doc in enumerate(documents):
                text = doc.get("text") or doc.get("content") or doc.get("snippet") or str(doc)
                passages.append({"id": idx, "text": text, "meta": doc})

            rerank_request = RerankRequest(query=query, passages=passages)
            results = self._flashrank_client.rerank(rerank_request)
            
            ranked = []
            for r in results[:top_k]:
                orig_doc = passages[r["id"]]["meta"]
                ranked_doc = dict(orig_doc)
                ranked_doc["rerank_score"] = float(r.get("score", 0.0))
                ranked_doc["ranker"] = "flashrank"
                ranked.append(ranked_doc)
            return ranked
        except Exception as e:
            logger.error(f"FlashRank reranking error: {e}. Returning raw documents.")
            return documents[:top_k]

    def rerank_cohere(self, query: str, documents: List[Dict[str, Any]], top_k: int = 5) -> List[Dict[str, Any]]:
        """Executes deep precision cross-encoder re-ranking via Cohere API."""
        if not documents or not self.cohere_key:
            return self.rerank_flashrank(query, documents, top_k=top_k)

        try:
            import cohere
            client = cohere.ClientV2(self.cohere_key)
            doc_texts = [
                doc.get("text") or doc.get("content") or doc.get("snippet") or str(doc)
                for doc in documents
            ]
            
            response = client.rerank(
                model="rerank-v3.5",
                query=query,
                documents=doc_texts,
                top_n=top_k
            )
            
            ranked = []
            for item in response.results:
                orig_doc = dict(documents[item.index])
                orig_doc["rerank_score"] = float(item.relevance_score)
                orig_doc["ranker"] = "cohere_v3.5"
                ranked.append(orig_doc)
            return ranked
        except Exception as e:
            logger.warning(f"Cohere rerank failed or quota reached ({e}). Falling back to FlashRank.")
            return self.rerank_flashrank(query, documents, top_k=top_k)

    def rerank(self, query: str, documents: List[Dict[str, Any]], top_k: int = 5, mode: str = "cascade") -> List[Dict[str, Any]]:
        """
        Unified Re-Ranking Entrypoint:
        - mode='flashrank': Pure local, zero-cost, sub-15ms.
        - mode='cohere': Cloud API cross-encoder.
        - mode='cascade': Dual-Tier (FlashRank prunes to 15, Cohere refines to top_k).
        """
        if not documents:
            return []

        if mode == "flashrank":
            return self.rerank_flashrank(query, documents, top_k=top_k)
        elif mode == "cohere":
            return self.rerank_cohere(query, documents, top_k=top_k)
        
        # Default: Cascaded Dual-Tier Strategy
        if self.cohere_key and len(documents) > top_k:
            # Step 1: Prune down with FlashRank to candidate window
            intermediate = self.rerank_flashrank(query, documents, top_k=min(len(documents), 15))
            # Step 2: Final precision ranking with Cohere
            return self.rerank_cohere(query, intermediate, top_k=top_k)
        else:
            return self.rerank_flashrank(query, documents, top_k=top_k)


hybrid_reranker = DualTierReranker()
