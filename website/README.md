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

## Structure

- `app/` — App Router pages, layout, and global styles.
- `public/` — Static assets (icons, images).
