---
title: Git 품질 검사
date: 2026-09-25
---

# Git 품질 검사

Vault 연결 미설정. 이 Markdown이 기록 원본이다.

PR에서 새 커밋의 비밀정보와 whitespace를 검사한다. 과거 전체 이력 감사는 별도이며,
PR 검사 통과는 기존 이력이나 앱 기능 전체의 안전을 보증하지 않는다. 기존 CI는 유지한다.
수동 workflow_dispatch는 전체 이력을 검사한다. 기본 브랜치 적용은 검토 후 PR 병합이 필요하다.

- [작업 이슈](https://github.com/Jaeman-Lee/call-advisor/issues/1)
- [공통 기준](https://github.com/Jaeman-Lee/dotfiles/blob/d8e2db63c3acd8507e3f330d983a2f219d4f5855/docs/git-quality.md)
