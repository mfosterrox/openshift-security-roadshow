# openshift-security-roadshow

=== Getting Started

=== Understanding the Basic Template Directory Structure

[source,sh]
----
./content/modules/ROOT/
├── assets
│   └── images                       # Images used in your content 
│       └── example-image.png
├── nav.adoc                         # Navigation for your lab
├── pages                            # Your content goes here
│   ├── index.adoc                   # First page of your lab, e.g. overview etc 
│   ├── module-02.adoc
│   └── module-03.adoc               # Sample lab has 3 modules including index.adoc
└── partials                         # You can add partials here, reusable content inserted inline into your modules
    └── example_partial.adoc
----

=== Development Cycle

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
