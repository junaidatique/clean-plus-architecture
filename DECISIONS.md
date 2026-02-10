# Decisions (Clean Plus Architecture)

Last updated: 2026-02-10

This file captures the agreed architectural decisions for this repo’s framework-agnostic “Clean Plus” architecture and its translation to tooling (Deptrac).

## 1) Naming / Boundaries

- **Module** = **bounded-context root** (what was previously called “domain” in some parts of the README).
- A **module** contains multiple **layers** (it is not itself a layer).
- **Domain layer** is *only* the pure domain model (entities/value objects/domain services/invariants), not “actions/tasks/use-cases”.

## 2) Layer Responsibilities

- `shared/contracts/`
  - Cross-module stable contracts: `Result`, `AppError` (and other truly shared types).
- `modules/<Module>/contracts/`
  - The module’s **published API** (allowed cross-module import surface): integration event contracts, plus optional published read-only query ports/DTOs.
- `modules/<Module>/domain/`
  - Pure domain logic (no IO, no framework, no logging).
- `modules/<Module>/application/`
  - Use-case orchestration and stable contracts owned by the core:
  - `ports/in/*` (input port interfaces)
  - `ports/out/*` (output port interfaces)
  - `dto/*` (boundary DTOs)
  - `actions/*` (input-port implementations; orchestrate tasks)
  - `tasks/*` (single-purpose steps; use output ports; no framework)
- `modules/<Module>/delivery/`
  - Primary adapters (HTTP/events/CLI): translate input → call input port → translate output.
  - Must depend on input ports + DTOs + shared contracts; must not depend on concrete actions/tasks/domain.
- `modules/<Module>/adapters/`
  - Secondary adapters (DB, external APIs, message bus): implement output ports.
  - May depend on framework/infrastructure libraries.
- `framework/composition-root/`
  - Wiring only (DI/container bindings, bootstrapping). May depend on everything.

## 3) Ports & Adapters (Why + What)

- **Input Port** = interface the delivery layer calls (owned by application/core).
- **Output Port** = interface the application/tasks call to reach the outside world (owned by application/core).
- **Adapters** implement output ports; delivery is the primary adapter for incoming IO.

## 4) Result + Error Contract

- Input ports return `Result<OutputDTO, AppError>`.
- **Tasks return `Result` too.**
- **Tasks never throw**: unexpected exceptions are caught and converted to `AppError` (e.g., code `UNEXPECTED`).
- Delivery maps `AppError.code` → HTTP status codes (README contains the mapping table).

## 5) Logging Rule

- Log at the top of `run()` for **application/delivery/adapters/framework** code using `[ClassName::run]`.
- **No logging in the domain layer** (keeps domain pure and deterministic).

## 6) Tooling Translation

- `deptrac.yaml` translates the README rules for a `src/` layout (framework-agnostic example).
- A separate Deptrac config is needed for Laravel’s typical `app/Domains/**` layout (different paths + vendor/framework namespaces). This repo includes a template file for that.

## 7) Inter-Module Communication (Modular Monolith)

- Cross-module imports are restricted to:
  - `shared/contracts/**`
  - `modules/<OtherModule>/contracts/**`
- Cross-module workflows for commands/POST are **async by default** via integration events.
- Queries/GET are **projection-first**; synchronous read-only lookups are the exception and must go through published contracts.

## 8) Reliability + Enforcement

- Integration events require **outbox + inbox/idempotency** (assume at-least-once delivery).
- Testing and tooling are part of the architecture:
  - Testing contract is **MUST** (domain/application/adapters/contracts).
  - Cross-module coupling checks are **MUST** in CI (layering + explicit cross-module import guard).
