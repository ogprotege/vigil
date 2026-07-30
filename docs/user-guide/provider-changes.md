# When a provider changes

Vigil reads usage from provider endpoints that mostly carry no public contract. A provider can rename fields, move values, or reshape its response at any time, without notice. Vigil treats an unreadable response as a fact to report, not a gap to paper over. This page explains the **Provider changed** state, what you can do about it, and how to report it so a fix can ship.

> Last reviewed: 2026-07-30
>
> Review again: when drift handling, unverified saves, re-linking, or the issue templates change

## What "Provider changed" means

Vigil maps every provider response against a strict expected shape, and the mapping must produce the windows and metrics that provider's contract requires. When the endpoint answers but a required value no longer maps safely — a missing field, a moved structure, an uninterpretable value — the account shows **Provider changed**.

Vigil never fills the gap with a guess. A partially mapped response is never presented as live, even when an unrelated value still parsed.

Experimental integrations in the [provider support matrix](../providers/support-matrix.md) are the most likely to change: their endpoints have no stable vendor contract yet, which is exactly why they are labeled experimental.

## What you will see

- The account shows **Provider changed** in Limits and account detail.
- The last accepted reading stays visible, aged: *"Provider changed, data from 2 hours ago."* That is the age of the retained data, not a check time. Checks keep running on the normal schedule, and the account recovers on its own the moment a response maps again.
- New readings, history observations, and threshold alerts for that account resume only after a response maps again.

## What you can do

1. **Update Vigil.** A newer build may already read the new response shape.
2. **Leave the account linked.** Nothing is lost by waiting: checks continue, retained values stay labeled with their age, and the account heals itself if the provider reverts or a fixed build arrives.
3. **Report the change** so a fix can ship — see the next section.

Removing and re-adding the account does not clear this state: the fresh link attempt verifies against the same changed response. When that happens, the link alert explains that this version of Vigil could not read the provider's usage fields and offers **Save anyway**, which stores the account and credential without an accepted reading; the first mappable response establishes one. Builds up to 0.15.0 (20) had no **Save anyway** for a changed provider — re-adding dead-ended — so update Vigil first if the option does not appear.

## Report a provider change

Open a [provider change report](https://github.com/ogprotege/vigil/issues/new?template=provider-change-report.yml) on GitHub. The template asks for the provider, your Vigil version and build, when the state started, and what you observed.

The fastest path to a fix is a sanitized capture of the provider's new response, because a mapping fix must be proven against real evidence — the fixture rules in this repository require a declared provenance for every response shape Vigil claims to support.

**Sanitize before posting.** Never post an API key, token, cookie, or session credential. Remove or replace account identifiers, organization identifiers, and email addresses. Usage numbers can be replaced with plausible values — the response *shape* is what a fix needs, not your data.

If you build the app yourself, a mapping fix follows the [provider contribution guide](../development/provider-contribution.md): the same contract, fixture, provenance, and parity-test checklist as a new integration.

## Any other problem

For anything that is not a provider change, open a [bug report](https://github.com/ogprotege/vigil/issues/new?template=bug-report.yml). Account detail offers a credential-free diagnostic export that can help — review its contents yourself before attaching it, like anything else you post publicly.
