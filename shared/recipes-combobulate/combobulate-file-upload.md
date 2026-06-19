# Recipe: Combobulate File Upload

**When to use**: Build request asks for file upload, attachment upload, document upload, image upload, or drag-and-drop file submission.

**What it gives you**: A two-step presign → PUT → complete flow wired to the Combobulate hosted uploads endpoint. Vanilla JS, zero combobulate branding in the rendered output.

---

## Placeholder contract

The URL below contains the literal string `COMBOBULATE_APP_ID`. The platform patches this with the real app UUID after build — the same convention as `GUMROAD_PLACEHOLDER_URL`. Do NOT replace it yourself; emit it verbatim in the generated HTML/JS.

---

## Endpoints

```
Step 1 — Presign
POST https://app.combobulate.dev/api/uploads/COMBOBULATE_APP_ID/<form_id>/presign
Content-Type: application/json
{ "filename": "photo.jpg", "content_type": "image/jpeg" }

Response 200:
{
  "upload_url": "https://...",   // PUT target (presigned S3/R2 URL)
  "upload_id": "uuid"            // opaque reference for Step 3
}

Step 2 — PUT file directly to upload_url
PUT <upload_url>
Content-Type: <original file content_type>
Body: raw file bytes

Response: 200 from storage provider

Step 3 — Complete
POST https://app.combobulate.dev/api/uploads/COMBOBULATE_APP_ID/<form_id>/complete
Content-Type: application/json
{ "upload_id": "<upload_id from Step 1>" }

Response 200:
{ "ok": true, "url": "https://..." }  // permanent public URL (if applicable)
```

- `COMBOBULATE_APP_ID` — literal placeholder, patched post-build.
- `<form_id>` — a slug you choose (e.g. `documents`, `photos`). Use a short, descriptive slug.
- CORS: the server echoes `Origin` for allowed `*.combobulate.dev` subdomains — cross-origin fetch works from the static site.

---

## HTML + JS snippet

```html
<div id="upload-widget">
  <label for="upload-file">Choose file</label>
  <input id="upload-file" type="file" accept="*/*" />
  <button id="upload-btn" disabled>Upload</button>
  <p id="upload-status" aria-live="polite"></p>
</div>

<script>
  (function () {
    var fileInput = document.getElementById("upload-file");
    var btn = document.getElementById("upload-btn");
    var status = document.getElementById("upload-status");
    var BASE =
      "https://app.combobulate.dev/api/uploads/COMBOBULATE_APP_ID/documents";

    fileInput.addEventListener("change", function () {
      btn.disabled = !fileInput.files.length;
    });

    btn.addEventListener("click", function () {
      var file = fileInput.files[0];
      if (!file) return;

      btn.disabled = true;
      status.textContent = "Preparing upload…";

      // Step 1: Presign
      fetch(BASE + "/presign", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ filename: file.name, content_type: file.type }),
      })
        .then(function (r) {
          return r.ok ? r.json() : Promise.reject(new Error("Presign failed"));
        })
        .then(function (presign) {
          status.textContent = "Uploading…";

          // Step 2: PUT to presigned URL
          return fetch(presign.upload_url, {
            method: "PUT",
            headers: { "Content-Type": file.type },
            body: file,
          }).then(function (r) {
            if (!r.ok) throw new Error("Upload failed");
            return presign.upload_id;
          });
        })
        .then(function (uploadId) {
          // Step 3: Complete
          return fetch(BASE + "/complete", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ upload_id: uploadId }),
          }).then(function (r) {
            return r.ok
              ? r.json()
              : Promise.reject(new Error("Complete failed"));
          });
        })
        .then(function () {
          status.textContent = "File uploaded successfully.";
          fileInput.value = "";
          btn.disabled = true;
        })
        .catch(function (err) {
          status.textContent =
            err.message || "Upload failed. Please try again.";
          btn.disabled = false;
        });
    });
  })();
</script>
```

---

## Notes

- Replace `documents` in `BASE` with your chosen `form_id` slug.
- The `accept` attribute on the `<input>` controls which file types the OS picker shows; adjust as needed (e.g. `accept="image/*"` for images only).
- Style with the site's existing CSS — no combobulate-specific classes.
- The presigned PUT URL expires (typically 15 minutes); do not cache it.
