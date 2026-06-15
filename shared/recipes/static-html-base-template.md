# Static HTML Base Template

Starter `index.html` for plain HTML + Tailwind v4 stacks. Drop into `static/index.html` and customize.

```html
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Site Title</title>
    <meta name="description" content="Site description for SEO" />
    <meta property="og:title" content="Site Title" />
    <meta property="og:description" content="Site description for SEO" />
    <link
      rel="icon"
      type="image/png"
      sizes="32x32"
      href="/images/favicon-32x32.png"
    />
    <link rel="stylesheet" href="/css/app.css" />
  </head>
  <body class="bg-white text-gray-900 font-sans">
    <nav
      class="fixed top-0 w-full bg-white/90 backdrop-blur border-b border-gray-100 z-50"
    >
      <div
        class="max-w-5xl mx-auto px-6 py-4 flex items-center justify-between"
      >
        <a href="/" class="font-bold text-lg">Brand</a>
        <div class="flex gap-6 text-sm">
          <a href="#contact" class="hover:text-blue-600">Contact</a>
        </div>
      </div>
    </nav>

    <section class="pt-28 pb-20 px-6 text-center">
      <h1 class="text-5xl font-bold leading-tight mb-6">Your Headline</h1>
      <p class="text-xl text-gray-600 mb-10">Supporting copy.</p>
    </section>

    <!-- Contact form: action="https://app.example.com/api/forms/{slug}/contact" method="POST" -->
    <!-- Replace {slug} with app slug. No platform branding footer on user apps. -->

    <footer
      class="py-8 px-6 border-t border-gray-100 text-center text-sm text-gray-500"
    >
      <p>Copyright &copy; <span id="copyright-year"></span> Brand Name.</p>
    </footer>

    <script>
      document.getElementById("copyright-year").textContent =
        new Date().getFullYear();
      // Smooth-scroll anchors: querySelectorAll('a[href^="#"]') → scrollIntoView({behavior:"smooth"})
    </script>
  </body>
</html>
```
