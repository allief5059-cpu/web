# ARTZZY STORE

A standalone game account marketplace built for Netlify and a dedicated Supabase project. Customers can browse as guests, contact the seller to buy, and request hourly rentals that start only after owner approval. No game login details are stored by the site.

## Technology

- React + Vite customer site, served as static files by Netlify
- Netlify Functions for administrator actions and guest rental requests
- A new Supabase project for Postgres, Auth, Storage, policies, and marketplace data
- Telegram contact links for seller-arranged purchases and rental questions

Supabase currently offers a free tier with a 500 MB database, 1 GB file storage, and 50,000 monthly active users. Its free projects may pause after a week of inactivity, so free tier is best for initial launch/testing. Netlify Free currently includes 300 usage credits per month; the site pauses at its hard free limit until the next billing cycle unless you upgrade. Neither service has a mandatory monthly fee on those free tiers, but inactivity/usage limits affect availability. Billplz charges depend on merchant account terms; payment is not free. See the current [Supabase plan page](https://supabase.com/pricing), [Netlify plan page](https://www.netlify.com/pricing/), and [Billplz API](https://www.billplz.com/api/).

## Local development

1. Install Node.js and npm, then run `npm install`.
2. Copy `.env.example` to `.env` and fill the two **public** Vite values from the new Supabase project.
3. Run `npm run dev`.

The storefront shows empty states until the database has games and accounts. Nothing is seeded or copied from another system.

## Create the separate database

1. Create a brand-new Supabase project for ARTZZY STORE. Do not point it at another business or bot project.
2. Open that project's SQL Editor and run [`supabase/migrations/202610020001_marketplace.sql`](supabase/migrations/202610020001_marketplace.sql), then [`supabase/migrations/202610020002_manual_contact_rentals.sql`](supabase/migrations/202610020002_manual_contact_rentals.sql), in that order. The second migration removes the unused credential column and adds guest hourly rental requests.
3. In Supabase Authentication, enable email/password. Configure the site URL and redirect URLs for the local Vite address and your Netlify site.
4. In Authentication → Users, create your own admin login, copy its user UUID, then run in the SQL Editor:

   ```sql
   update public.profiles set role = 'admin' where id = 'YOUR_AUTH_USER_UUID';
   ```

   Admin privileges are intentionally assigned out-of-band; registration metadata cannot grant admin access.
5. The migration creates an empty public `store-media` image bucket with public reads and admin-only writes. Account login credentials are not part of the website inventory.

## Netlify deployment

1. Push this project to a new Git repository, then import that repository into Netlify.
2. Build settings are in `netlify.toml`: command `npm run build`, publish directory `dist`, functions directory `netlify/functions`.
3. Set these environment variables in Netlify (Project configuration → Environment variables):

   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`
   - `SUPABASE_SERVICE_ROLE_KEY` (server-only secret)

4. Deploy/redeploy after setting environment variables. Add the Netlify URL to Supabase Auth's allowed redirect URLs.
5. In Supabase, promote the admin account as above. Sign in at `/login`, then open `/admin` to add games and accounts.
6. Open `/admin` while signed in to see rental requests. The admin page refreshes the request list every 15 seconds while it remains open; it does not send a separate Telegram or email notification.

## Purchases and rentals

- Purchases open a Telegram message to `@Artz_v2`; there is no online payment or QR checkout.
- Customers can request a rental as a guest with a nickname, optional Telegram username, and 1–168 hours. The total is the listing's hourly price multiplied by the requested hours.
- A private random token lets the guest check the request status from the same browser. The waiting page also links to Telegram so they can message the seller.
- Requests appear in the Admin page. Approving one starts its countdown using database time and rejects other pending requests for that account. Declining does not start the timer.
- Admin changes pass through a Netlify function that checks the user's Supabase JWT and `profiles.role = 'admin'`. Sensitive actions are recorded in `admin_audit_log`.

## Operational notes

- No private Supabase keys, database users, game rows, account records, or customer rental requests are committed here. `.env.example` contains placeholders only.
- The site needs a separate Supabase project and Netlify server environment variables before it can accept rental requests.
- Back up the Supabase project and monitor its free quotas; Supabase Free does not include automatic backups and can pause inactive projects.
- The store console accepts image URLs or uploads JPG/PNG/WebP images up to 5 MB. It supports inventory, rental request approval, legacy order viewing, customer viewing, and auditing.
- Run the local checks with `node --test tests/rental-rules.test.mjs` and `npm run build`.
