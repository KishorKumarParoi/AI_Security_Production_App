"""Automated Faithfulness and Hallucination Verification Runner."""

from deepeval.metrics import HallucinationMetric
from deepeval.test_case import LLMTestCase


def evaluate_faithfulness(question: str, context: list[str], answer: str) -> float:
    """Evaluate factual adherence of answer to supplied context."""
    metric = HallucinationMetric(threshold=0.7)
    test_case = LLMTestCase(
        input=question,
        actual_output=answer,
        context=context
    )
    metric.measure(test_case)
    return metric.score
