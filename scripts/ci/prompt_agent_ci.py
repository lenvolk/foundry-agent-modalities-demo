"""CI helper for the Prompt Agent: publish a version from instructions.md, or invoke it.

Usage:
  python scripts/ci/prompt_agent_ci.py publish
  python scripts/ci/prompt_agent_ci.py invoke "<prompt text>"

Reads FOUNDRY_PROJECT_ENDPOINT, AZURE_AI_MODEL_DEPLOYMENT_NAME and
FOUNDRY_PROMPT_AGENT_NAME from the environment. Signs in with DefaultAzureCredential,
which picks up the Azure CLI session created by azure/login (OIDC) in GitHub Actions.
"""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition
from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential

ROOT = Path(__file__).resolve().parents[2]
INSTRUCTIONS = ROOT / "prompt_agent" / "instructions.md"


def _env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default or "").strip()
    if not value:
        sys.exit(f"::error::{name} is not set.")
    return value


def _output(key: str, value: str) -> None:
    """Write a step output when running in GitHub Actions."""
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(f"{key}={value}\n")


def _client() -> AIProjectClient:
    return AIProjectClient(
        endpoint=_env("FOUNDRY_PROJECT_ENDPOINT"), credential=DefaultAzureCredential()
    )


def publish() -> None:
    """Create a new version only when instructions or model changed (content hash)."""
    name = _env("FOUNDRY_PROMPT_AGENT_NAME", "field-demo-support-triage-prompt")
    model = _env("AZURE_AI_MODEL_DEPLOYMENT_NAME")
    instructions = INSTRUCTIONS.read_text(encoding="utf-8")
    digest = hashlib.sha256(f"{model}\n{instructions}".encode()).hexdigest()[:16]

    with _client() as project:
        try:
            latest = project.agents.get(agent_name=name).versions.latest
            current = (latest.metadata or {}).get("content_sha")
        except ResourceNotFoundError:
            latest, current = None, None

        if latest is not None and current == digest:
            print(f"Unchanged (content_sha={digest}). Keeping version {latest.version}.")
            _output("version", str(latest.version))
            _output("changed", "false")
            return

        agent = project.agents.create_version(
            agent_name=name,
            definition=PromptAgentDefinition(model=model, instructions=instructions),
            description="Sample: declarative support-case triage rubric (published by CI).",
            metadata={
                "content_sha": digest,
                "git_sha": os.environ.get("GITHUB_SHA", "local")[:12],
                "published_by": "github-actions",
            },
        )
        print(f"Published {agent.name} version {agent.version} (content_sha={digest}).")
        _output("version", str(agent.version))
        _output("changed", "true")


def invoke(prompt: str) -> None:
    name = _env("FOUNDRY_PROMPT_AGENT_NAME", "field-demo-support-triage-prompt")
    with _client() as project, project.get_openai_client() as openai:
        response = openai.responses.create(
            input=prompt,
            extra_body={"agent_reference": {"name": name, "type": "agent_reference"}},
        )
        print(response.output_text)


if __name__ == "__main__":
    match sys.argv[1:]:
        case ["publish"]:
            publish()
        case ["invoke", prompt]:
            invoke(prompt)
        case _:
            sys.exit(__doc__)
