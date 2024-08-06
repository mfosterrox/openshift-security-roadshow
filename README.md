# openshift-security-roadshow

=== Getting Started

. Edit your content in `content/modules/ROOT/pages/`
. Run `./utilities/lab-build.sh` to build your html
. Run `./utilities/lab-serve.sh` to view the roadshow locally via http://localhost:8000/ 
. Use `git` to branch and commit your work
. Push your work to your repo
.. You should use `git tags` or `git branches` in production
.. However development items default to the head of `main`

== Variables

Other vars can also be set there, such as `ssh_user` and `ssh_password`, and referenced inline in the lab content by using the `\{foo}` syntax.

This is another var, or asciidoc attribute, from `./content/antora.yml` {my_var}
