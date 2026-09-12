# Hiring interview — backend engineer

## Style
First person, past tense, specific. Lead with what I did, then the number that
shows it worked. One story per answer, three or four sentences. Never say
"we" when I mean "I". Never say synergy, leverage, or journey.

## Context
I'm a backend engineer with six years in payments. Currently at Northwind, a
12-person startup, where I own the ledger service.

### The disagreement story
My manager wanted to ship dual-writes to the new ledger in one release. I
argued for a read-shadow phase first. I lost the argument, we shipped, and we
corrupted 400 rows in staging. We caught it before production. I built the
shadow harness afterward and it's caught two more bugs since. What I changed:
I now bring a written rollback plan to that conversation instead of an opinion.

### The scaling story
Payment volume tripled in a quarter. The write path was doing a synchronous
fraud lookup per transaction. I moved it behind a queue with a 200 ms budget
and a fail-open default. p99 went from 1.4 s to 180 ms. The fail-open was the
controversial part; I wrote the risk memo and the fraud team signed it off.

### Weaknesses, honestly
I over-invest in tooling early. I built a migration framework for what turned
out to be two migrations. I now timebox that to a day and revisit.

### Don't say
Don't claim I led the team; I didn't. Don't mention the salary conversation.

## Terms
Northwind | north wind | northwood
p99 | p ninety nine | p 99
