# Roadmap

Decisions recorded here so they are not re-litigated later.

## Investments and stocks

Wanted, not built. When it happens, these are the conclusions already reached.

### What the existing machinery gives for free

A brokerage statement is a PDF like any other, so ingestion, the dual
attachment/text route, the provider layer and the repair loop all apply
unchanged. A `PortfolioReport` would be a second schema authored the same way
the audit schema was, rendered per provider by the same dialect renderer, and
validated by the same validator. None of the AI plumbing needs to move.

### The one thing that must not be widened

`Money` holds two-decimal minor units. That is exactly right for cash and
wrong for securities: share prices run to four or more decimals, and a
fractional share quantity is not money at all.

**Do not widen `Money`.** It stays the cash type. Securities get a separate
scaled pair — a `Price` with an explicit scale and a `Quantity` — and the
conversion to `Money` happens once, at the point a position is valued. This is
cheap to decide now and expensive to retrofit after a hundred call sites
assume two decimals.

### What this app should and should not do

The same engine that truthfully reports what you spent cannot tell you what a
stock will do. A blunt, confident tone applied to trade picks would be this
app's worst feature rather than its best, and "buy low, sell high" as an
instruction to act on is a different product with different obligations.

What the machinery does do well, and what the feature should therefore be:

- cost basis, realised and unrealised gain
- platform, FX and spread fees you are actually paying, annualised
- cash drag — uninvested balance sitting in a dealing account
- concentration risk, stated as a fact rather than a recommendation
- dividend income folded into the cashflow picture

That list is all arithmetic over documents, which is what the arithmetic
verifier already exists to check. Forecasting is not.

## Upstreaming PDF attachments

`packages/audit_core/lib/src/providers/document_provider.dart` exists only
because `transcript_core`'s `StructureRequest` is text-only. The additive
change upstream is a `List<Attachment>` on `StructureRequest` plus the
content-block rendering in the Anthropic and Gemini adapters.

Both classes here delegate identity, capabilities and connection testing to
the upstream adapter and override nothing but the request body, so when that
lands these are deleted rather than migrated. The server's
`providers/adapters.py` already carries attachments natively and would not
change.

Worth doing once the attachment path has been exercised against real
statements, and not before — EchoCodex should not take a change to its core
on the strength of this app's fixtures.

## Also outstanding

- **iOS.** Builds from the same Flutter source and needs no new code, but it
  has never been compiled: that needs a Mac or a macOS CI runner.
- **Nothing has run against a real provider.** Every test uses recorded
  responses, a stub model server, and generated PDFs. The wire formats match
  the documented APIs and EchoCodex's working adapters, but the first audit of
  a real bank statement is still unproven.
- **A desktop build.** Flutter would give Linux, macOS and Windows from the
  same source, and the appliance already covers the "big screen" case, so this
  is low priority.
