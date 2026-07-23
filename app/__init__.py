"""Syno Mihomo Gateway panel — dynamic device policy + persistent stats.

FastAPI service core (epic gateway-panel). SQLite is the single source of
truth; the reconciler projects it into the #63 rule-provider files and
verifies the controller loaded them. Secrets come only from the
environment; nothing here logs or echoes them.
"""
