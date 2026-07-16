# openshift-security-roadshow

Public site (GitHub Pages): **https://mfosterrox.github.io/openshift-security-roadshow/**

=== Getting Started

. Edit your content in `content/modules/ROOT/pages/`
. Run `make build` to build your html (or `npx antora --fetch default-site.yml`)
. Run `make serve` to view the roadshow locally via http://localhost:8080/
. Use `git` to branch and commit your work
. Push your work to your repo
.. You should use `git tags` or `git branches` in production
.. However development items default to the head of `main`

Pushes to `main` publish the site via `.github/workflows/gh-pages.yml` (Antora playbook: `gh-pages-site.yml`).

== Variables

Other vars can also be set there, such as `ssh_user` and `ssh_password`, and referenced inline in the lab content by using the `\{foo}` syntax.

This is another var, or asciidoc attribute, from `./content/antora.yml` {my_var}
