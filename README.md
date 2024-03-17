# openshift-security-roadshow

=== Getting Started

. Create a git repo from this template
. Clone the repo and `cd` into it
. Run ./utilities/lab-serve
. Open http://localhost:8080 in your browser
. Run ./utilities/lab-build to build your html

Your lab should now update and on day 1 will look more or less like this:

image::.images/lab-image.png[Lab Image]

Now you are ready to go!  You can start editing the files in the `content/modules/ROOT/pages/` directory.

**Today** you have to run `./utilites/build` to rebuild your html but *very shortly* we will be adding live updating.
I.E. on every save the lab will re-build in real time.
In addition, many modern editors such as Visual Studio Code offer live Asciidoc Preview extensions.

=== Understanding the Basic Template Directory Structure

[source,sh]
----
./content/modules/ROOT/
├── assets
│   └── images                       # Images used in your content 
│       └── example-image.png
├── examples                         # You can add downloadable assets here 
│   └── example-bash-script.sh       # e.g. an example bash script
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
. Run `./utilities/build` to build your html
. Use `git` to branch and commit your work
. Push your work to your repo
.. You should use `git tags` or `git branches` in production
.. However development items default to the head of `main`

=== Configuring your Lab 

Project Zero Lab repos have 3 *yaml* files that control the build and deployment of your lab.
However _typically_ you will only need to only make very few edits 

[source,sh]
----
├── content
│   └── antora.yml                  # You can add "inline vars" here to render within your content
├── zero-touch-config.yml            # 
└── zero-touch-site.yml
----


The `lab_name` var, known as an asciidoc attribute, above was set in `./content/antora.yml` and can be used to set the lab_name or title of your content.
You are both free to change its value and if you prefer to use a different var name, you can change the value of `lab_name`, for example to `title` in `./content/antora.yml` and then reference it in your content as `\{title}`.
me

== Variables

Other vars can also be set there, such as `ssh_user` and `ssh_password`, and referenced inline in the lab content by using the `\{foo}` syntax.

This is another var, or asciidoc attribute, from `./content/antora.yml` {my_var}

== Writing your lab

Whatever type of content you are writing we'll refer to your *content* as "your lab" in this document.

=== Lab structure


Wether you are writing a lab

* First, we will build a monolithic application already compiled as RPM packages and put it into a container. This will allow us to deploy the application, copy it between machines, and update it separately from the operating system. This process affords us a portable and easily maintained component instead of tightly coupling the application with your operating system maintenance.

* In closing we will build a second container on a different operating system version that makes an application not packaged into RPMs. This will be similar to a web application deployment, positioning the correct files at the right locations. To do this, we will pull a project from GitHub and position the component files within our container image. The purpose of this is to achieve a portable application container that can deploy on several different versions of Red Hat Enterprise Linux. This also provides the benefit of decoupling your application maintenance, which would all happen by building new containers versus operating system maintenance. The container is no longer reliant on the operating system installed on the machine where the application is deployed.


. Now let's examine this cluster a bit more by describing the cluster (the `$GUID` environment variable is already set for you so you can immediately describe your individual cluster):
+
[source,sh,role=execute]
----
podman ps
----
+
.Sample Output
[source,texinfo,subs="attributes"]
----
CONTAINER ID  IMAGE                        COMMAND           CREATED      STATUS      PORTS                 NAMES
2dcfee9e50c4  docker.io/library/httpd:2.4  httpd-foreground  3 hours ago  Up 3 hours  0.0.0.0:8080->80/tcp  showroom-httpd
----




