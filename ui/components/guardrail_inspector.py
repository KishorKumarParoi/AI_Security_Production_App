"""Streamlit sidebar component for inspecting active guardrails and colang definitions."""

import streamlit as st
from app.guardrails.colang_rules import RAIL_INDICATORS


def render_guardrail_inspector():
    with st.expander("🛡️ Active Guardrail Rules", expanded=False):
        st.markdown("**Protected Topics:**")
        st.markdown("- Kubernetes Architecture & Operators\n- Intel Hardware Acceleration\n- Enterprise Networking")
        st.markdown("---")
        st.markdown(f"**Loaded Rail Indicators:** `{len(RAIL_INDICATORS)} active triggers`")
