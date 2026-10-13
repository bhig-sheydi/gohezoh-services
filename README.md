# Kwik-Parsel

Kwik-Parsel is the delivery and fulfillment product by Gohezo Integrated Services. This React + TypeScript app is built with Vite; Supabase migrations are in `supabase/migrations`.

## Start the app

```sh
npm install
npm run dev
```

## Supabase client configuration

Copy `.env.example` to `.env.local` and set the project URL and publishable key. Never put a Supabase secret or service-role key in a `VITE_` variable or browser code.

The customer workflow supports delivery requests reviewed by Kwik-Parsel Operations.

Staff and partner signup creates an application for Super Admin review. See [staff access](docs/STAFF_ACCESS.md) for approval, revocation, and invitation details.
