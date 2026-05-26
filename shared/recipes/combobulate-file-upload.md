# Combobulate File Upload

Use when user asks for file or photo upload on static site (HTML, Hugo, React, Vue).

Platform handles presigned S3 URLs and metadata — no backend code needed. Visitors upload directly to S3; site owner gets WhatsApp notification with 7-day download link.

## Endpoints

```
POST https://app.combobulate.dev/api/uploads/APP_ID/FORM_ID/presign
POST https://app.combobulate.dev/api/uploads/APP_ID/FORM_ID/complete
```

- `APP_ID` — app's UUID (substitute real value, never leave as literal placeholder)
- `FORM_ID` — short identifier, e.g. `contact`, `portfolio`, `inquiry`
- Presign returns `{"ok": true, "object_key": "...", "put_url": "...", "expires_in": 300}`
- Complete returns `{"ok": true, "upload_id": "...", "get_url": "..."}`
- Rate limited: 20 presign requests per hour per IP per app

## Limits

- Max file size: 25 MB per file
- Max files per app: 100
- Max total storage per app: 5 GB
- Pending slots (presign issued but not completed) count toward quota, reclaimed after 1 hour

## Two-step upload flow

1. Browser POSTs filename + content_type + size to `/presign` → receives short-lived PUT URL
2. Browser PUTs file directly to S3 using PUT URL (no Phoenix involvement)
3. Browser POSTs `object_key` to `/complete` → platform verifies blob and notifies owner

File never passes through Phoenix — goes from visitor's browser directly to S3.

## HTML + JavaScript snippet

```html
<form id="upload-form">
  <input
    type="file"
    id="file-input"
    accept="image/*,.pdf,.doc,.docx"
    required
  />
  <button type="submit">Upload file</button>
  <p id="upload-status" style="display:none"></p>
</form>

<script>
  const APP_ID = "YOUR_APP_UUID";
  const FORM_ID = "contact";
  const BASE = "https://app.combobulate.dev/api/uploads";

  document
    .getElementById("upload-form")
    .addEventListener("submit", async function (e) {
      e.preventDefault();
      const file = document.getElementById("file-input").files[0];
      const status = document.getElementById("upload-status");

      if (!file) return;

      if (file.size > 25 * 1024 * 1024) {
        status.textContent = "File is too large. Maximum size is 25 MB.";
        status.style.display = "block";
        return;
      }

      status.textContent = "Uploading…";
      status.style.display = "block";

      try {
        // Step 1: get a presigned PUT URL
        const presignRes = await fetch(`${BASE}/${APP_ID}/${FORM_ID}/presign`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            filename: file.name,
            content_type: file.type || "application/octet-stream",
            size: file.size,
          }),
        });

        if (!presignRes.ok) {
          const err = await presignRes.json();
          if (presignRes.status === 413) {
            status.textContent = "File is too large. Maximum size is 25 MB.";
          } else if (presignRes.status === 409) {
            status.textContent =
              "Storage limit reached. Please try again later.";
          } else if (presignRes.status === 429) {
            status.textContent =
              "Too many uploads. Please wait a moment and try again.";
          } else {
            status.textContent = "Upload failed. Please try again.";
          }
          return;
        }

        const { object_key, put_url } = await presignRes.json();

        // Step 2: PUT file directly to S3
        const putRes = await fetch(put_url, {
          method: "PUT",
          headers: { "Content-Type": file.type || "application/octet-stream" },
          body: file,
        });

        if (!putRes.ok) {
          status.textContent = "Upload failed. Please try again.";
          return;
        }

        // Step 3: confirm the upload
        const completeRes = await fetch(
          `${BASE}/${APP_ID}/${FORM_ID}/complete`,
          {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ object_key }),
          },
        );

        if (completeRes.ok) {
          document.getElementById("upload-form").style.display = "none";
          status.textContent = "File uploaded successfully!";
        } else {
          status.textContent = "Upload verification failed. Please try again.";
        }
      } catch (err) {
        status.textContent =
          "Network error. Please check your connection and try again.";
      }
    });
</script>
```

## React / Vue usage

Extract three-step logic into `async function handleUpload(file)` and call from `onSubmit` or button handler. Fetch calls are identical — only event wiring differs.

```js
// React example
async function handleUpload(file) {
  const presign = await fetch(`${BASE}/${APP_ID}/${FORM_ID}/presign`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      filename: file.name,
      content_type: file.type || "application/octet-stream",
      size: file.size,
    }),
  });
  if (!presign.ok) throw new Error("presign failed");
  const { object_key, put_url } = await presign.json();

  await fetch(put_url, {
    method: "PUT",
    headers: { "Content-Type": file.type || "application/octet-stream" },
    body: file,
  });

  const complete = await fetch(`${BASE}/${APP_ID}/${FORM_ID}/complete`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ object_key }),
  });
  if (!complete.ok) throw new Error("complete failed");
  return complete.json();
}
```

## Hugo partial

Drop HTML form inside `layouts/partials/upload-form.html` and call from any template with `{{ partial "upload-form.html" . }}`. No Hugo-specific changes — pure HTML + JS.

## Owner notification

Once `complete` succeeds, app owner receives a WhatsApp message:

```
📎 New file on <app name> (contact):

photo.jpg (1.2 MB)
Download (expires in 7 days): https://...
```

No extra config needed — platform sends it automatically.

## CORS

CORS allowed automatically for:

- `*.combobulate.dev` (platform-hosted subdomains)
- Verified custom domains on the app

No extra headers needed in site config.

## Combining with a contact form

To attach file alongside contact form submission, run upload first, then include `object_key` (or `get_url`) as hidden field in contact form POST to `/api/forms/APP_ID/FORM_ID`. Owner sees message and download link in same WhatsApp thread.
