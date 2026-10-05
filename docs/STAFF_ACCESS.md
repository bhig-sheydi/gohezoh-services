# Staff access and Super Admin

Customer signup grants only the Customer role. Staff and logistics partners choose their category during signup. The database stores it as a pending application; it never grants the requested role from signup metadata. The applicant must confirm their email before approval. A Super Admin can approve or reject applications, link a Partner applicant to an active partner company, and revoke staff roles from the access-control page. Role checks use the database on every request, so revocation takes effect for existing sessions without waiting for a new login.

Only `admin@gohezohservices.org` and `Info@gohezoservices.org` are eligible for the protected Super Admin role. Their accounts must be created through a server-side Supabase invitation, with the invite redirected to `https://gohezoh-services.vercel.app/?setup=1`. The invite recipient sets their own password on that page. No administrator password or service key belongs in browser code or this repository.

Supabase Auth's Site URL is `https://gohezoh-services.vercel.app/`. The hosted project's redirect allow-list includes the Vercel site and localhost:5173 for local development. The confirmation and invite templates use `{{ .ConfirmationURL }}`, which carries the configured redirect. `supabase/config.toml` mirrors these URL settings for local development.
