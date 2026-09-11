# Name this conversation

## Style
How answers should be shaped. This is your instruction to the model, passed through
verbatim — nothing is added to it, so anything you don't say here, it won't do.

Worth being specific about:
- Length and form: "three to five bullets", "one short paragraph", "no preamble".
- Whether it's read aloud: "each bullet a sentence I can say as written".
- What to do with gaps: "never invent a figure; if the material below doesn't cover it,
  say what's missing in one line".
- Register: blunt, warm, technical, non-technical.

## Context
Everything the answer should be built from. Paste freely — this is the section to be
generous with. Ordinary markdown works: bullets, tables, numbers, and `###` or deeper
headings. A `##` line starts a new section, so keep those for Style, Context and Terms.

It is sent on every request but cached after the first, so length costs you very little
after the first ask of a session. Anything up to a few hundred pages is comfortable.

## Terms
Words the recogniser gets wrong in this domain, one per line:

    Canonical Spelling | what it hears | another thing it hears

The first field is what appears in the transcript. Later fields are what to correct from.
Short acronyms need explicit aliases; longer names are also matched approximately.
