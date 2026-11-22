# web/ — owner rule (2026-11-22)

**Nobody reads the website yet.** It shows the latest and best only:

- the current champion forecast, **Timestral + physics** (Timestral conditioned on
  the lead-1 physics clear; cv45 record rMAE 0.555 vs the D-1 naive);
- the current physics clear (**cv45**);
- the current methods.

So:

- no legacy or experimental series;
- no history of versions or methods that nobody knows;
- no caveats about superseded things.

When something is superseded, **replace it on the site; don't label it "legacy"**.
This applies to every page, including the copy on `about.html` and `models.html`.

Plain HTML/CSS/JS, no build step (`README.md`). Before calling a view done, look at
a headless screenshot at desktop and phone width, in light and dark.
