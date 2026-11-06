# LemurCam Website

The public marketing/landing site for **LemurCam**, the macOS virtual webcam
app. Hosted at [lemur.cam](https://lemur.cam).

This lives in the `website/` directory of the LemurCam app repository. It is a
self-contained Next.js project with no build dependency on the macOS app source.

## Tech Stack

- [Next.js](https://nextjs.org) 16 (App Router)
- React 19, TypeScript
- Tailwind CSS 4

## Getting Started

Run all commands from inside `website/`:

```bash
npm install    # Install dependencies
npm run dev    # Start the dev server at http://localhost:3000
npm run build  # Production build
npm run lint   # ESLint
```

Edit the landing page in `app/page.tsx`; the dev server hot-reloads on save.

The site loads no web fonts and makes no network requests at build time: text
uses the system font stack. It follows the visitor's light or dark setting.

## Structure

- `app/` — App Router pages, layout, and global styles. `globals.css` holds the
  page colors and the `--mac-*` colors the recreations use in each appearance.
- `app/components/` — Working recreations of the app's menu bar popover,
  setup window and Settings window, and of what other apps receive from the
  LemurCam camera. Each is built from the SwiftUI source it names in its
  header comment, which also lists its deliberate liberties. `mac.tsx` has the
  shared window chrome and controls; `samples.ts` the sample cameras.
- `public/` — Static assets (icons, images).

When the app's interface changes, update the matching recreation so the site
keeps showing real strings, layouts and states.
