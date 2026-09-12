# Technical deep-dive — my own architecture

## Style
Explain the decision, then the tradeoff I accepted. Concrete numbers where I
have them. No buzzwords, no diagrams-in-words. Three or four sentences, and
say "I don't know" rather than guessing at something I didn't measure.

## Context
I own the ledger service at Northwind. Go, Postgres, one Kafka topic.

### Keeping the write path fast
Traffic tripled in a quarter. The write path did a synchronous fraud lookup
per transaction, and p99 hit 1.4 s. I moved the lookup behind a queue with a
200 ms budget and a fail-open default, so a slow fraud service degrades the
check rather than the payment. p99 came down to 180 ms. The tradeoff is a
window where a fraudulent transaction can clear; we bounded it at 200 ms and
the fraud team signed off in writing.

### Why Postgres and not a queue-of-record
People ask why the ledger isn't event-sourced. We considered it and chose a
single Postgres table with an append-only constraint, because the audit story
is one query and our whole team already knows Postgres. It will stop working
somewhere north of 50K writes a second. We're at 900.

### Idempotency
Every write carries a client-supplied key, unique-indexed. Retries collapse.
This is the single change that removed most of our on-call pages.

## Terms
Postgres | post gres | postgress
Kafka | kaff ka
p99 | p ninety nine | p 99
idempotency | item potency | idem potency
