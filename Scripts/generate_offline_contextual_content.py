#!/usr/bin/env python3
"""Build the Batch 8C candidate pack from an authenticated source lock.

The normal build path reads only the checked-in source lock, authenticates every
provenance path with `git show <commit>:<path>`, then emits deterministic JSON.
`--bootstrap-lock` is a one-time candidate curation aid for producing the first
lock from the source repository's local editorial sidecar. It never approves
content and its output remains behind the human review Release gate.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import unicodedata
import urllib.parse
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "docs/content/offline-contextual-content-source-lock-v1.json"
REGISTER_PATH = (
    ROOT / "docs/content/0003-offline-contextual-content-source-register.md"
)
RESOURCE_DIR = ROOT / "Unmanual/Resources/PublicContent"
CANDIDATE_PATH = (
    RESOURCE_DIR / "offline-contextual-content-candidate-v1.json"
)
RELEASE_STATE_PATH = (
    RESOURCE_DIR / "offline-contextual-content-release-state-v1.json"
)

SOURCE_REPOSITORY = "https://github.com/AwantedRaccoon/MTF-Unmanual"
SOURCE_COMMIT = "f39474389831840366c23fd274208319802bf2a5"
CONTENT_VERSION = "offline-contextual-content-candidate.1"
GENERATED_AT = "2026-07-31"
GUIDE_STALE_DATE = "2026-07-27"

ALLOWED_HOSTS = {
    "academic.oup.com",
    "ashpublications.org",
    "creativecommons.org",
    "github.com",
    "glaad.org",
    "pflag.org",
    "pubmed.ncbi.nlm.nih.gov",
    "transcare.ucsf.edu",
    "wpath.org",
    "www.asha.org",
    "www.asrm.org",
    "www.cdc.gov",
    "www.endocrine.org",
    "www.hopkinsmedicine.org",
    "www.mayoclinic.org",
    "www.nhc.gov.cn",
    "www.plannedparenthood.org",
    "www.psychiatry.org",
    "www.rainbowhealthontario.ca",
    "www.samhsa.gov",
    "www.thetrevorproject.org",
    "www.transcarebc.ca",
    "www.transhub.org.au",
    "www.who.int",
}

BOUNDARY = (
    "教育性必要摘要；不读取个人记录，不作身份判定、诊断、处方、剂量、"
    "目标范围或个体化医疗解释。"
)

UNREFERENCED_REGIONAL_CLAIMS = {
    "card.hiv-testing-prep-021": (
        "国内 PrEP 可及性因地区而异，可到正规医院挂号（感染科）"
        "或当地疾控/PrEP 项目咨询，通常自费。",
    ),
    "card.prep-hrt-022": (
        "大陆可经感染科或本地 PrEP 项目（疾控、部分社区组织）获取与随访。",
    ),
    "card.hpv-vaccine-024": (
        "国内 HPV 疫苗按获批价型有不同适用年龄（九价已扩龄 "
        "9–45 岁女性、有国产九价），可经社区卫生服务中心或"
        "正规预约平台接种；具体以本地获批价型为准。",
    ),
    "card.surgery-options-026": (
        "（中国大陆此类手术通常自费、医保一般不覆盖）",
    ),
    "card.finding-affirming-therapist-033": (
        "国内缺公开的友善咨询师名录，更多靠跨性别社群转介、"
        "有性别相关门诊经验的医院、社群口碑来找，而非依赖"
        '"LGBT 友好"标签检索；并提醒诊断证明只有精神科医生能开。',
    ),
}

SOURCE_LOCK_SOURCE_KEYS = {
    "id",
    "rightsHolder",
    "title",
    "versionOrPublishedAt",
    "retrievedAt",
    "expiresAt",
    "sourceStatus",
    "url",
    "licenseIdentifier",
    "licenseURL",
    "distributionMode",
    "applicableRegions",
    "applicablePopulations",
    "boundary",
}

SOURCE_LOCK_CARD_KEYS = {
    "id",
    "title",
    "summary",
    "applicabilityBoundary",
    "contentType",
    "category",
    "aliases",
    "sourceIDs",
    "displayOrder",
    "contentVersion",
    "retrievedAt",
    "expiresAt",
    "originalURL",
    "provenance",
}

SOURCE_LOCK_PROVENANCE_KEYS = {
    "sourceRepository",
    "sourceCommit",
    "sourcePath",
    "sourceFileSHA256",
    "adaptationStatus",
    "modificationNote",
}


def run_git(repository: Path, *arguments: str) -> bytes:
    return subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout


def git_show(repository: Path, path: str) -> bytes:
    return run_git(repository, "show", f"{SOURCE_COMMIT}:{path}")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalize(value: Any) -> Any:
    if isinstance(value, str):
        return unicodedata.normalize("NFC", value)
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, dict):
        return {
            unicodedata.normalize("NFC", key): normalize(item)
            for key, item in value.items()
        }
    return value


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        normalize(value),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def canonical_digest(value: Any) -> str:
    return sha256(canonical_bytes(value))


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def reject_duplicate_json_keys(
    pairs: list[tuple[str, Any]],
) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def load_source_lock(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_json_keys,
        )
    except json.JSONDecodeError as error:
        raise ValueError("source lock is not valid JSON") from error
    if not isinstance(value, dict):
        raise ValueError("source lock must be a JSON object")
    return value


def stable_source_id(source_id: str) -> str:
    return "source." + source_id.replace("_", "-")


def stable_card_id(card_id: str) -> str:
    suffix = card_id.removeprefix("card_").replace("_", "-")
    return "card." + suffix


def fixed_https_url(value: str) -> bool:
    if "\\" in value or "?" in value or "#" in value:
        return False
    if not value.startswith("https://"):
        return False
    lowered = value.lower()
    if any(token in lowered for token in ("%2f", "%5c", "%40")):
        return False
    parsed = urllib.parse.urlsplit(value)
    if (
        parsed.scheme != "https"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port is not None
        or parsed.hostname is None
        or parsed.hostname != parsed.hostname.lower()
        or parsed.hostname.endswith(".")
        or parsed.hostname not in ALLOWED_HOSTS
    ):
        return False
    raw_authority = value[len("https://") :].split("/", 1)[0]
    if ":" in raw_authority or raw_authority != parsed.hostname:
        return False
    raw_segments = parsed.path.split("/")
    return not any(
        segment in {".", ".."}
        or urllib.parse.unquote(segment) in {".", ".."}
        for segment in raw_segments
    )


def valid_source_path(value: str) -> bool:
    if (
        not value
        or value.startswith("/")
        or "\\" in value
        or "\0" in value
        or not value.isascii()
    ):
        return False
    segments = value.split("/")
    return all(
        re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", segment)
        is not None
        for segment in segments
    )


def markdown_summary(raw: bytes) -> tuple[str, str]:
    text = raw.decode("utf-8")
    lines = text.splitlines()
    if not lines or not lines[0].startswith("# "):
        raise ValueError("source card has no H1")
    title = lines[0][2:].strip()
    body_lines: list[str] = []
    for line in lines[1:]:
        if line.startswith("**接着可以看：**"):
            break
        body_lines.append(line)
    body = "\n".join(body_lines).strip()
    body = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", body)
    body = body.replace("**", "").replace("`", "")
    body = strip_markdown_blockquote_markers(body)
    body = re.sub(r"\n{3,}", "\n\n", body).strip()
    if not body:
        raise ValueError("source card has no summary")
    return title, body


def strip_markdown_blockquote_markers(value: str) -> str:
    return re.sub(r"(?m)^[ \t]*>[ \t]?", "", value)


def adapt_candidate_summary(card_id: str, value: str) -> str:
    adapted = strip_markdown_blockquote_markers(value)
    for claim in UNREFERENCED_REGIONAL_CLAIMS.get(card_id, ()):
        claim_count = adapted.count(claim)
        if claim_count != 1:
            raise ValueError(
                "expected regional claim count is "
                f"{claim_count} for frozen card: {card_id}"
            )
        adapted = adapted.replace(claim, "", 1)
    return re.sub(r"\n{3,}", "\n\n", adapted).strip()


def require_exact_keys(
    value: Any,
    expected: set[str],
    context: str,
) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise ValueError(f"{context} has unknown or missing keys")
    return value


def require_nonempty_string(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{context} must be a non-empty string")
    return value


def require_string_array(value: Any, context: str) -> list[str]:
    if (
        not isinstance(value, list)
        or not all(isinstance(item, str) and item for item in value)
    ):
        raise ValueError(f"{context} must be an array of non-empty strings")
    return value


def category_for(card_id: str, topics: set[str]) -> str:
    joined = " ".join([card_id, *sorted(topics)]).lower()
    if any(
        token in joined
        for token in ("surgery", "vaginoplasty", "vulvoplasty")
    ):
        return "surgery"
    if any(
        token in joined
        for token in ("sexual_health", "prep", "hiv", "sti", "hpv")
    ):
        return "sexualHealth"
    if any(
        token in joined
        for token in ("preventive", "bone", "breast_screening", "prostate")
    ):
        return "preventiveCare"
    if any(
        token in joined
        for token in ("voice", "hair_removal", "tucking", "presentation")
    ):
        return "voiceAndPresentation"
    if any(
        token in joined
        for token in ("mental", "therapy", "dysphoria", "support_network")
    ):
        return "mentalWellbeing"
    if any(
        token in joined
        for token in ("coming_out", "privacy", "family", "ally")
    ):
        return "privacyAndRelationships"
    if any(
        token in joined
        for token in ("hrt", "care_pathway", "fertility", "contraception")
    ):
        return "hrtAndCare"
    return "identityAndTerms"


def unique_aliases(claims: list[dict[str, Any]]) -> list[str]:
    aliases: list[str] = []
    for claim in claims:
        for candidate in (claim.get("topic", ""), claim.get("subtopic", "")):
            candidate = candidate.strip()
            if (
                candidate
                and len(candidate) <= 80
                and candidate.casefold()
                not in {value.casefold() for value in aliases}
            ):
                aliases.append(candidate)
    return aliases[:24]


def bootstrap_lock(source_repository_path: Path) -> dict[str, Any]:
    head = run_git(source_repository_path, "rev-parse", "HEAD").decode().strip()
    if head != SOURCE_COMMIT:
        raise ValueError(f"source HEAD {head} is not frozen commit")

    data_root = source_repository_path / "data"
    cards = read_jsonl(data_root / "cards/cards.jsonl")
    claims_by_id = {
        item["claim_id"]: item
        for item in read_jsonl(data_root / "claims/claims.jsonl")
    }
    sources_by_id = {
        item["source_id"]: item
        for item in read_jsonl(data_root / "sources/sources.jsonl")
    }

    selected: list[
        tuple[dict[str, Any], list[dict[str, Any]]]
    ] = []
    excluded: dict[str, str] = {}
    for card in cards:
        claims = [claims_by_id.get(item) for item in card["evidence_claim_ids"]]
        if any(item is None for item in claims):
            excluded[card["card_id"]] = "claim 引用缺失"
            continue
        typed_claims = [item for item in claims if item is not None]
        if not all(item.get("next_review_due") for item in typed_claims):
            excluded[card["card_id"]] = "至少一个 claim 缺少 next_review_due"
            continue
        if card["card_id"] == "card_crisis_support_032":
            excluded[card["card_id"]] = "高时效热线及非固定 URL"
            continue
        if any(
            source_id not in sources_by_id
            for source_id in card["evidence_source_ids"]
        ):
            excluded[card["card_id"]] = "source 引用缺失"
            continue
        selected.append((card, typed_claims))

    if len(selected) != 45 or len(excluded) != 14:
        raise ValueError(
            f"unexpected selection: {len(selected)} selected, "
            f"{len(excluded)} excluded"
        )

    selected.sort(
        key=lambda item: int(item[0]["card_id"].rsplit("_", 1)[-1])
    )
    used_source_ids = sorted(
        {
            source_id
            for card, _ in selected
            for source_id in card["evidence_source_ids"]
        }
    )
    if len(used_source_ids) != 45:
        raise ValueError(f"expected 45 bibliography sources, got {len(used_source_ids)}")

    source_expiries: dict[str, list[str]] = {
        source_id: [] for source_id in used_source_ids
    }
    locked_cards: list[dict[str, Any]] = []
    for display_order, (card, claims) in enumerate(selected, start=1):
        source_path = f"cards/zh-CN/{card['card_id']}.md"
        raw = git_show(source_repository_path, source_path)
        title, summary = markdown_summary(raw)
        expires_at = min(item["next_review_due"] for item in claims)
        for source_id in card["evidence_source_ids"]:
            source_expiries[source_id].append(expires_at)
        source_rows = [
            sources_by_id[source_id]
            for source_id in card["evidence_source_ids"]
        ]
        retrieved_at = max(row["retrieved_at"] for row in source_rows)
        topics = {item.get("topic", "") for item in claims}
        locked_cards.append(
            {
                "id": stable_card_id(card["card_id"]),
                "title": title,
                "summary": summary,
                "applicabilityBoundary": BOUNDARY,
                "contentType": "questionAnswer",
                "category": category_for(card["card_id"], topics),
                "aliases": unique_aliases(claims),
                "sourceIDs": [
                    stable_source_id(item)
                    for item in card["evidence_source_ids"]
                ],
                "displayOrder": display_order,
                "contentVersion": CONTENT_VERSION,
                "retrievedAt": retrieved_at,
                "expiresAt": expires_at,
                "originalURL": (
                    f"{SOURCE_REPOSITORY}/blob/{SOURCE_COMMIT}/{source_path}"
                ),
                "provenance": {
                    "sourceRepository": SOURCE_REPOSITORY,
                    "sourceCommit": SOURCE_COMMIT,
                    "sourcePath": source_path,
                    "sourceFileSHA256": sha256(raw),
                    "adaptationStatus": "modified",
                    "modificationNote": (
                        "从冻结短卡提取必要摘要并移除站内导航；"
                        "未加入个体化医疗输出。"
                    ),
                },
            }
        )

    locked_sources: list[dict[str, Any]] = []
    for source_id in used_source_ids:
        source = sources_by_id[source_id]
        if not source["verification_status"].startswith("live_checked_"):
            raise ValueError(f"source not live-checked: {source_id}")
        if not fixed_https_url(source["url"]):
            raise ValueError(f"source URL violates fixed contract: {source_id}")
        locked_sources.append(
            {
                "id": stable_source_id(source_id),
                "rightsHolder": source["organization"],
                "title": source["title"],
                "versionOrPublishedAt": (
                    source["last_updated_or_published"] or "未标注"
                ),
                "retrievedAt": source["retrieved_at"],
                "expiresAt": min(source_expiries[source_id]),
                "sourceStatus": "current",
                "url": source["url"],
                "licenseIdentifier": "rights-reserved-link-only",
                "licenseURL": None,
                "distributionMode": "linkOnly",
                "applicableRegions": [source["region"] or "not-specified"],
                "applicablePopulations": (
                    source["audience"] or ["public"]
                ),
                "boundary": (
                    "只保存书目信息和固定链接，不打包外部正文、"
                    "图表、图片或受限数据。"
                ),
            }
        )

    guides = [
        {
            "id": "guide.regimen-field",
            "title": "把方案字段当作忠实记录",
            "summary": (
                "药物名称、剂型和给药途径是不同字段。原样记录标签或处方信息，"
                "不要因为名称相近就合并，也不要由 App 推算等效剂量。"
            ),
            "applicabilityBoundary": BOUNDARY,
            "contentType": "recordingGuide",
            "category": "recordsAndVisits",
            "aliases": ["方案字段", "剂型", "给药途径", "route"],
            "sourceIDs": [
                stable_source_id("ucsf_feminizing_hormone_therapy"),
                stable_source_id("transhub_feminising_hormones"),
                stable_source_id("rainbow_health_ontario_feminizing_ht"),
            ],
            "displayOrder": 46,
            "contentVersion": CONTENT_VERSION,
            "retrievedAt": GUIDE_STALE_DATE,
            "expiresAt": GUIDE_STALE_DATE,
            "sourcePath": "cards/zh-CN/card_estrogen_routes_054.md",
            "modificationNote": (
                "改编为方案录入字段说明；删除途径比较，"
                "不提供剂量、推荐或等效换算。"
            ),
        },
        {
            "id": "guide.lab-recording",
            "title": "保留化验原件与采样上下文",
            "summary": (
                "记录报告日期、采样时间、单位、参考范围与原始附件。"
                "一次标红不能脱离病史、检测方法和采样条件替代医疗解释。"
            ),
            "applicabilityBoundary": BOUNDARY,
            "contentType": "recordingGuide",
            "category": "recordsAndVisits",
            "aliases": ["化验记录", "报告原件", "采样上下文", "单位"],
            "sourceIDs": [
                stable_source_id("endocrine_society_2017"),
                stable_source_id("rainbow_health_ontario_feminizing_ht"),
            ],
            "displayOrder": 47,
            "contentVersion": CONTENT_VERSION,
            "retrievedAt": GUIDE_STALE_DATE,
            "expiresAt": GUIDE_STALE_DATE,
            "sourcePath": (
                "archive/quick/zh-CN/036-hrt-follow-up-records-and-labs.md"
            ),
            "modificationNote": (
                "改编为本地记录说明；不提供目标范围、"
                "个体化化验解释或调药建议。"
            ),
        },
        {
            "id": "guide.visit-preparation",
            "title": "首诊与复诊前的准备清单",
            "summary": (
                "准备完整药物与补剂清单、重要病史、既往报告、"
                "变化与问题。清单帮助把事实带进会诊，不替代医生评估。"
            ),
            "applicabilityBoundary": BOUNDARY,
            "contentType": "visitChecklist",
            "category": "recordsAndVisits",
            "aliases": ["首诊准备", "复诊准备", "就诊清单"],
            "sourceIDs": [
                stable_source_id("endocrine_society_2017"),
                stable_source_id("asrm_trans_fertility_access_2021"),
                stable_source_id("trans_care_bc_primary_care_toolkit"),
            ],
            "displayOrder": 48,
            "contentVersion": CONTENT_VERSION,
            "retrievedAt": GUIDE_STALE_DATE,
            "expiresAt": GUIDE_STALE_DATE,
            "sourcePath": (
                "archive/quick/zh-CN/034-hrt-first-visit-preparation.md"
            ),
            "modificationNote": (
                "改编为就诊准备清单摘要；不提供处方、"
                "检查套餐或开始治疗的判定。"
            ),
        },
    ]
    for guide in guides:
        source_path = guide.pop("sourcePath")
        modification_note = guide.pop("modificationNote")
        raw = git_show(source_repository_path, source_path)
        guide["originalURL"] = (
            f"{SOURCE_REPOSITORY}/blob/{SOURCE_COMMIT}/{source_path}"
        )
        guide["provenance"] = {
            "sourceRepository": SOURCE_REPOSITORY,
            "sourceCommit": SOURCE_COMMIT,
            "sourcePath": source_path,
            "sourceFileSHA256": sha256(raw),
            "adaptationStatus": "modified",
            "modificationNote": modification_note,
        }
        locked_cards.append(guide)

    return {
        "lockVersion": "1",
        "sourceRepository": SOURCE_REPOSITORY,
        "sourceCommit": SOURCE_COMMIT,
        "contentVersion": CONTENT_VERSION,
        "generatedAt": GENERATED_AT,
        "selectionEvidence": (
            "Candidate-only curation lock derived from the source repository's "
            "local ignored editorial sidecar; every packed prose provenance "
            "path is independently authenticated with git show."
        ),
        "excludedCards": excluded,
        "sources": locked_sources,
        "cards": locked_cards,
    }


def verify_lock(lock: dict[str, Any], repository: Path) -> None:
    expected_keys = {
        "lockVersion",
        "sourceRepository",
        "sourceCommit",
        "contentVersion",
        "generatedAt",
        "selectionEvidence",
        "excludedCards",
        "sources",
        "cards",
    }
    require_exact_keys(
        lock,
        expected_keys,
        "source lock",
    )
    if (
        lock["lockVersion"] != "1"
        or lock["sourceRepository"] != SOURCE_REPOSITORY
        or lock["sourceCommit"] != SOURCE_COMMIT
        or lock["contentVersion"] != CONTENT_VERSION
    ):
        raise ValueError("source lock identity does not match the frozen contract")
    require_nonempty_string(lock["generatedAt"], "generatedAt")
    require_nonempty_string(lock["selectionEvidence"], "selectionEvidence")
    if not isinstance(lock["excludedCards"], dict) or not all(
        isinstance(key, str)
        and key
        and isinstance(reason, str)
        and reason
        for key, reason in lock["excludedCards"].items()
    ):
        raise ValueError(
            "excludedCards must map non-empty strings to non-empty reasons"
        )
    if not isinstance(lock["sources"], list) or not isinstance(
        lock["cards"],
        list,
    ):
        raise ValueError("source lock sources and cards must be arrays")
    if len(lock["sources"]) != 45 or len(lock["cards"]) != 48:
        raise ValueError("source lock must contain exactly 45 sources and 48 cards")
    if len(lock["excludedCards"]) != 14:
        raise ValueError("source lock must record exactly 14 excluded short cards")

    for index, source_value in enumerate(lock["sources"]):
        source = require_exact_keys(
            source_value,
            SOURCE_LOCK_SOURCE_KEYS,
            f"source[{index}]",
        )
        for key in (
            "id",
            "rightsHolder",
            "title",
            "versionOrPublishedAt",
            "retrievedAt",
            "expiresAt",
            "sourceStatus",
            "url",
            "licenseIdentifier",
            "distributionMode",
            "boundary",
        ):
            require_nonempty_string(source[key], f"source[{index}].{key}")
        if source["licenseURL"] is not None:
            require_nonempty_string(
                source["licenseURL"],
                f"source[{index}].licenseURL",
            )
        require_string_array(
            source["applicableRegions"],
            f"source[{index}].applicableRegions",
        )
        require_string_array(
            source["applicablePopulations"],
            f"source[{index}].applicablePopulations",
        )
        if source["sourceStatus"] not in {
            "current",
            "knownUnavailable",
        }:
            raise ValueError(f"source[{index}] has invalid sourceStatus")
        if source["distributionMode"] not in {
            "linkOnly",
            "redistributable",
        }:
            raise ValueError(
                f"source[{index}] has invalid distributionMode"
            )

    for index, card_value in enumerate(lock["cards"]):
        card = require_exact_keys(
            card_value,
            SOURCE_LOCK_CARD_KEYS,
            f"card[{index}]",
        )
        for key in (
            "id",
            "title",
            "summary",
            "applicabilityBoundary",
            "contentType",
            "category",
            "contentVersion",
            "retrievedAt",
            "expiresAt",
            "originalURL",
        ):
            require_nonempty_string(card[key], f"card[{index}].{key}")
        require_string_array(card["aliases"], f"card[{index}].aliases")
        require_string_array(
            card["sourceIDs"],
            f"card[{index}].sourceIDs",
        )
        if (
            isinstance(card["displayOrder"], bool)
            or not isinstance(card["displayOrder"], int)
            or card["displayOrder"] <= 0
        ):
            raise ValueError(
                f"card[{index}].displayOrder must be a positive integer"
            )
        provenance = require_exact_keys(
            card["provenance"],
            SOURCE_LOCK_PROVENANCE_KEYS,
            f"card[{index}].provenance",
        )
        for key in SOURCE_LOCK_PROVENANCE_KEYS:
            require_nonempty_string(
                provenance[key],
                f"card[{index}].provenance.{key}",
            )
        if provenance["adaptationStatus"] not in {
            "unmodified",
            "modified",
        }:
            raise ValueError(
                f"card[{index}] has invalid adaptationStatus"
            )

    run_git(repository, "cat-file", "-e", f"{SOURCE_COMMIT}^{{commit}}")
    source_ids = [item["id"] for item in lock["sources"]]
    card_ids = [item["id"] for item in lock["cards"]]
    if len(source_ids) != len(set(source_ids)):
        raise ValueError("duplicate source ID in source lock")
    if len(card_ids) != len(set(card_ids)):
        raise ValueError("duplicate card ID in source lock")
    source_id_set = set(source_ids)

    path_digests: dict[str, str] = {}
    for card in lock["cards"]:
        provenance = card["provenance"]
        path = provenance["sourcePath"]
        if not valid_source_path(path):
            raise ValueError(f"invalid repository-relative source path: {path}")
        actual = sha256(git_show(repository, path))
        if actual != provenance["sourceFileSHA256"]:
            raise ValueError(f"source digest mismatch: {path}")
        previous = path_digests.setdefault(path, actual)
        if previous != actual:
            raise ValueError(f"one source path maps to multiple digests: {path}")
        if provenance["sourceCommit"] != SOURCE_COMMIT:
            raise ValueError(f"wrong source commit: {path}")
        if provenance["sourceRepository"] != SOURCE_REPOSITORY:
            raise ValueError(f"wrong source repository: {path}")
        if not set(card["sourceIDs"]).issubset(source_id_set):
            raise ValueError(f"dangling source reference: {card['id']}")

    for source in lock["sources"]:
        if not fixed_https_url(source["url"]):
            raise ValueError(f"invalid fixed source URL: {source['id']}")


def build_pack(lock: dict[str, Any]) -> dict[str, Any]:
    cards: list[dict[str, Any]] = []
    for locked in lock["cards"]:
        card = dict(locked)
        card["provenance"] = dict(locked["provenance"])
        summary_without_markdown = strip_markdown_blockquote_markers(
            card["summary"]
        )
        adapted_summary = adapt_candidate_summary(
            card["id"],
            card["summary"],
        )
        if adapted_summary != card["summary"]:
            card["summary"] = adapted_summary
            existing_note = card["provenance"][
                "modificationNote"
            ].rstrip("。；")
            adaptation_notes: list[str] = []
            if card["id"] in UNREFERENCED_REGIONAL_CLAIMS:
                adaptation_notes.append(
                    "移除未被当前 sourceIDs 支持的地区性断言"
                )
            if summary_without_markdown != locked["summary"]:
                adaptation_notes.append(
                    "把 Markdown 引用标记转换为纯文本"
                )
            card["provenance"]["modificationNote"] = (
                existing_note
                + "；"
                + "；".join(adaptation_notes)
            )
        unsigned = dict(card)
        card["cardDigest"] = canonical_digest(unsigned)
        cards.append(card)

    anchors: list[dict[str, Any]] = []
    for card in cards:
        anchors.append(
            {
                "id": "anchor.pocket-" + card["id"].replace(".", "-"),
                "scenario": "pocketAppendix",
                "purpose": "在随身附页离线查阅该必要摘要。",
                "displayOrder": card["displayOrder"],
                "cardID": card["id"],
            }
        )
    extras = [
        (
            "anchor.regimen-field",
            "regimenField",
            "解释方案名称、剂型和给药途径字段。",
            "guide.regimen-field",
        ),
        (
            "anchor.lab-recording",
            "labRecording",
            "解释化验原件、单位和采样上下文。",
            "guide.lab-recording",
        ),
        (
            "anchor.regimen-analysis-source",
            "regimenAnalysisSource",
            "从方案分析进入对应离线教育摘要。",
            "card.hrt-monitoring-005",
        ),
        (
            "anchor.visit-preparation",
            "visitPreparation",
            "主动打开首诊与复诊准备清单。",
            "guide.visit-preparation",
        ),
        (
            "anchor.timeline-record",
            "timelineRecord",
            "从记录详情解释保留原件和上下文。",
            "guide.lab-recording",
        ),
    ]
    for anchor_id, scenario, purpose, card_id in extras:
        anchors.append(
            {
                "id": anchor_id,
                "scenario": scenario,
                "purpose": purpose,
                "displayOrder": 1,
                "cardID": card_id,
            }
        )

    pack = {
        "manifest": {
            "schemaVersion": "1",
            "contentVersion": CONTENT_VERSION,
            "locale": "zh-Hans",
            "generatedAt": GENERATED_AT,
            "retrievedAt": max(
                source["retrievedAt"] for source in lock["sources"]
            ),
            "expiresAt": min(
                source["expiresAt"] for source in lock["sources"]
            ),
            "sourceCommit": SOURCE_COMMIT,
            "contentDigest": "",
            "sourceCount": len(lock["sources"]),
            "cardCount": len(cards),
            "scenarioAnchorCount": len(anchors),
            "review": {
                "status": "candidate",
                "ownerRole": "内容、医疗与 App Review 分类复核责任人",
                "contentReviewerDisplayName": None,
                "medicalReviewerDisplayName": None,
                "completedAt": None,
                "scope": (
                    "48 张场景化必要摘要、45 条外部书目、"
                    "53 个显式场景 anchor 与 CC BY-SA 授权链"
                ),
            },
            "classificationStatus": "pending",
        },
        "sources": lock["sources"],
        "cards": cards,
        "scenarioAnchors": anchors,
        "attribution": {
            "sourceRepository": SOURCE_REPOSITORY,
            "sourceCommit": SOURCE_COMMIT,
            "creator": "MtF Manual contributors",
            "licenseIdentifier": "CC-BY-SA-4.0",
            "licenseURL": (
                "https://creativecommons.org/licenses/by-sa/4.0/"
            ),
            "adaptationStatus": "modified",
            "modificationNote": (
                "把冻结短卡与三个主题改编为 App 离线必要摘要，"
                "移除站内导航并增加产品适用边界。"
            ),
            "shareAlikeStatement": (
                "改编内容按 CC BY-SA 4.0 或兼容许可证共享；"
                "外部书目和链接目标不因此被再许可。"
            ),
        },
    }
    unsigned_pack = json.loads(json.dumps(pack, ensure_ascii=False))
    del unsigned_pack["manifest"]["contentDigest"]
    pack["manifest"]["contentDigest"] = canonical_digest(unsigned_pack)
    return pack


def build_release_state() -> dict[str, Any]:
    return {
        "schemaVersion": "1",
        "status": "pendingHumanReviewAndClassification",
        "contentVersion": CONTENT_VERSION,
        "message": (
            "等待真实人类内容复核、医疗复核与 App Review 分类结论；"
            "candidate 资源必须从 Release 排除。"
        ),
        "candidateResourceExcluded": True,
        "contentReviewApproved": False,
        "medicalReviewApproved": False,
        "classificationResolved": False,
        "approvedResourceName": None,
    }


def build_register(lock: dict[str, Any], pack: dict[str, Any]) -> str:
    lines = [
        "# Batch 8C 场景化离线内容候选来源登记",
        "",
        "- 状态：Candidate / 待真实人类内容、医疗与 App Review 分类复核",
        f"- 冻结来源：`{SOURCE_REPOSITORY}` @ `{SOURCE_COMMIT}`",
        f"- 内容版本：`{CONTENT_VERSION}`",
        "- 数量：48 张摘要、45 条外部书目、53 个场景 anchor",
        "- 技术合同：[ADR 0020](../architecture/0020-batch-8c-offline-contextual-content.md)",
        "",
        "## 认证边界",
        "",
        "候选清单最初依据来源仓库本机的 ignored 编辑 sidecar 筛选；该 sidecar 不在冻结提交中，",
        "因此它不能单独证明 Release 级 claim 复核。机器可读 lock 已把本次候选选择和外部书目",
        "冻结在 App 仓库；生成器对每张实际打包摘要的来源路径执行",
        "`git show <commit>:<path>` 并重算 SHA-256。此边界是 candidate-only，不能冒充",
        "真实人类内容或医疗复核。",
        "",
        "## 卡片与来源文件锁",
        "",
        "| App ID | 类型 | 分类 | 到期 | 来源路径 | SHA-256 |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for card in pack["cards"]:
        provenance = card["provenance"]
        lines.append(
            f"| `{card['id']}` | `{card['contentType']}` | "
            f"`{card['category']}` | `{card['expiresAt']}` | "
            f"`{provenance['sourcePath']}` | "
            f"`{provenance['sourceFileSHA256']}` |"
        )
    lines.extend(
        [
            "",
            "## 外部书目（仅链接）",
            "",
            "| Source ID | 权利人/机构 | 标题 | 查阅 | 到期 | 固定 URL |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
    )
    for source in pack["sources"]:
        lines.append(
            f"| `{source['id']}` | {source['rightsHolder']} | "
            f"{source['title']} | `{source['retrievedAt']}` | "
            f"`{source['expiresAt']}` | {source['url']} |"
        )
    lines.extend(
        [
            "",
            "上述外部书目全部为 `linkOnly`，不打包第三方正文、图表、图片或受限数据，",
            "也不因本项目的 CC BY-SA 4.0 署名而被再许可。",
            "",
            "## 明确排除",
            "",
        ]
    )
    for card_id, reason in sorted(lock["excludedCards"].items()):
        lines.append(f"- `{card_id}`：{reason}")
    lines.append("")
    return "\n".join(lines)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(
        value,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    ) + "\n"
    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source-repository",
        type=Path,
        required=True,
        help="local clone containing the frozen source commit",
    )
    parser.add_argument(
        "--bootstrap-lock",
        action="store_true",
        help="curate the initial candidate lock from the local editorial sidecar",
    )
    arguments = parser.parse_args()

    if arguments.bootstrap_lock:
        lock = bootstrap_lock(arguments.source_repository)
        write_json(LOCK_PATH, lock)
    else:
        lock = load_source_lock(LOCK_PATH)

    verify_lock(lock, arguments.source_repository)
    pack = build_pack(lock)
    if (
        pack["manifest"]["sourceCount"] != 45
        or pack["manifest"]["cardCount"] != 48
        or pack["manifest"]["scenarioAnchorCount"] != 53
    ):
        raise ValueError("generated counts do not match the Batch 8C contract")
    write_json(CANDIDATE_PATH, pack)
    write_json(RELEASE_STATE_PATH, build_release_state())
    REGISTER_PATH.write_text(
        build_register(lock, pack),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
