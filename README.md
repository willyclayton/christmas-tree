# The Family Tree

A shared Christmas tree for the family. Anyone with the link can doodle an
ornament (or use a photo), hang it on the tree, and everyone else sees it
appear right away. No login.

- `index.html`: the whole app (plain HTML, CSS and JavaScript)
- `config.js`: where your Supabase URL and key go
- `supabase/schema.sql`: the database table, rules and functions
- `og.png`: the preview image shown when the link is texted

Until `config.js` is filled in, the page runs in **preview mode**: it works
fully, but ornaments are saved only in your own browser.

## Setup (about 10 minutes)

### 1. Create the database

1. Sign up at [supabase.com](https://supabase.com) and create a new project
   (the free plan is plenty).
2. In Supabase, open **SQL Editor**, paste the whole of
   `supabase/schema.sql`, and press **Run**.
3. Set your admin secret (your password for removing ornaments). Clear the
   editor, paste this with your own secret in the quotes, and press **Run**:

   ```sql
   update private.tree_admin
   set secret_hash = encode(sha256(convert_to('YOUR-SECRET-HERE', 'UTF8')), 'hex');
   ```

   Never put the real secret in this repository.

### 2. Connect the page

1. In Supabase, open **Project Settings > API** (or **Connect**).
2. Copy the **Project URL** and the **anon / publishable key** into
   `config.js`:

   ```js
   window.TREE_CONFIG = {
     supabaseUrl: "https://abcdefgh.supabase.co",
     supabaseAnonKey: "eyJ..."
   };
   ```

   These two values are meant to be public. The rules in `schema.sql` are
   what protect the data.
3. Commit and push.

### 3. Publish with GitHub Pages

1. On GitHub, open the repository's **Settings > Pages**.
2. Under **Build and deployment**, choose **Deploy from a branch**, pick the
   branch that holds these files and the `/ (root)` folder, then **Save**.
3. After a minute the site is live at
   `https://willyclayton.github.io/christmas-tree/`. Text that link to the
   family.

### 4. Optional: custom domain (tree.willyclayton.com)

1. At your DNS provider, add a `CNAME` record: `tree` pointing to
   `willyclayton.github.io`.
2. In **Settings > Pages > Custom domain**, enter `tree.willyclayton.com`,
   save, and tick **Enforce HTTPS** once it is offered.
3. In `index.html`, change the two `og.png` addresses near the top to
   `https://tree.willyclayton.com/og.png` so the text-message preview keeps
   working.

## Removing an ornament

- **Your own:** tap it, then **Remove** (works from the browser you made it in).
- **Anyone's (admin):** open `https://<your site>/?admin=<your secret>`, tap
  an ornament, then **Remove**. Keep that link to yourself.

## How it stays safe and tidy

- Anyone can read the ornaments; nobody can write to the table directly.
  Hanging and removing go through two database functions that check
  everything.
- Limits: 3 ornaments per person (per browser), 150 per hour for the whole tree,
  400 in total. Names are capped at 16 characters, drawings at 60 strokes /
  1600 points, photos are shrunk to a 240 x 240 JPEG in the browser before
  they are sent.
- The page treats every row as untrusted: values are clamped, colors come
  from a fixed palette, and names are inserted as plain text.
- Ornaments shrink slightly as the tree fills, new ones are offered the
  emptiest spot, and the counter at the top opens a list of every ornament.
- Live updates use Supabase Realtime. The page also re-checks every 30
  seconds and whenever it is reopened, so nobody misses an ornament.

## Trying it locally

```sh
python3 -m http.server 8000
```

Open `http://localhost:8000` in two windows. In preview mode, an ornament
hung in one window appears in the other (same browser only).
