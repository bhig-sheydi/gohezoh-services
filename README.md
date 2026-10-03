# Gohezoh Services

React + TypeScript customer and operations app built with Vite. Supabase migrations are in `supabase/migrations`.

## Start the app

```sh
npm install
npm run dev
```

## Supabase client configuration

Copy `.env.example` to `.env.local` and set the project URL and publishable key. Never put a Supabase secret or service-role key in a `VITE_` variable or browser code.

The first planned product flow is customer service requests reviewed by Gohezoh Operations.
