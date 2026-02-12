---
name: clean-plus-architecture
description: Use when implementing, refactoring, or reviewing a modular monolith that must follow the Clean Plus rulebook (modules/contracts, Result/AppError, integration events, Deptrac boundaries, and cross-module import guard).
---

# Clean Plus Architecture

## Overview

Clean Plus is a **rulebook-driven** modular monolith architecture:

- **Modules** are bounded contexts.
- Cross-module dependencies are allowed only via **published contracts** (`<module>/contracts/**`) and **shared stable contracts** (`shared/contracts/**`).
- Business logic stays in **domain + application**; IO stays in **delivery + adapters**.
- Enforcement is automated via **Deptrac** (layering) + **clean-plus-guard.rb** (cross-module import guard).

The canonical spec is `clean-plus.rules.yaml`.

## When to Use

Use this skill when you need to:

- Generate code (or validate existing code) against the Clean Plus boundaries.
- Prevent “big ball of mud” inter-module coupling.
- Introduce a new module / new use-case while keeping strict separation.
- Prepare architecture checks for CI (`deptrac` + `clean-plus-guard.rb`).

## Inputs

- Rulebook: `clean-plus.rules.yaml`
- Guard: `clean-plus-guard.rb`
- Deptrac config:
  - Framework-agnostic: `deptrac.yaml`
  - Laravel example: `deptrac.laravel.yaml`

## Profile Selection

Choose the profile that matches the project layout:

- `framework_agnostic_src`: projects with `src/modules/**`
- `laravel_app_domains`: projects with `app/Domains/**`

If multiple profiles match, require the user to pick one.

## Core Workflow

### 1) Identify the module boundary

- Confirm which module is being changed.
- If the change crosses modules:
  - Commands/POST: **integration events + projections** (default).
  - Queries/GET: **projection-first**; synchronous read-only lookup is an exception and must use contracts + ACL.

### 2) Keep cross-module coupling explicit

- A module must not import another module’s `domain/**`, `application/**`, `delivery/**`, or `adapters/**`.
- Allowed cross-module imports:
  - `shared/contracts/**`
  - `<other_module>/contracts/**`

### 3) Keep the core framework-agnostic

- `domain/`: pure, deterministic, no IO, no framework, no logging.
- `application/`: Actions + Tasks + Ports + DTOs; framework-agnostic.
- Actions/Tasks return `Result<T, AppError>`.
- Tasks do not throw; unexpected exceptions map to `AppError(UNEXPECTED)`.

### 4) Enforce before claiming “done”

Run both checks (and fix violations):

#### Cross-module import guard

```bash
ruby clean-plus-guard.rb --profile framework_agnostic_src
# or
ruby clean-plus-guard.rb --profile laravel_app_domains
```

#### Deptrac (layering)

```bash
vendor/bin/deptrac analyze deptrac.yaml
# or (Laravel)
vendor/bin/deptrac analyze deptrac.laravel.yaml
```

## Common Failure Modes (and what to do)

- **Shared contracts becoming a dumping ground**: move business logic back into the owning module; keep only stable primitives/contracts.
- **Module A imports Module B internals**: replace with Module B `contracts/**` or switch to integration events.
- **Sync chains for commands**: redesign as events + projections (outbox/inbox/idempotency).
- **Controllers depending on concrete Actions**: depend on input-port interfaces only.
