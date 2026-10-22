# Changelog

All notable changes to the Enterprise AI Security & Production RAG project are documented here.

## [v1.1.0] - 2026-10-22

### Added
- **Security & Validation**: Strict Pydantic V2 schemas with regex sanitization and whitespace trimming.
- **Adversarial Defenses**: Input delimiter sanitization, prompt-leakage prevention rail, and multi-lingual greeting handlers.
- **Latency & Performance**: LRU in-memory query embedding cache and xxhash-based chunk deduplication.
- **Resilience**: Exponential backoff with full jitter for upstream Portkey LLM calls.
- **Agent Memory**: Conversation history compression and long-thread summarization.
- **Enterprise Middleware**: Distributed tracing Correlation ID middleware and Token Bucket rate limiter.
- **Observability**: Kubernetes `/health/live` and `/health/ready` endpoints, and Prometheus metrics exporter.
- **CI/CD Automation**: GitHub Actions pipeline expanded with Bandit AST security auditing and Pytest suites.

## [v1.0.0] - 2026-10-22
- Initial production release of Enterprise Agentic RAG with NVIDIA NeMo Guardrails, LangGraph, and Streamlit UI.
