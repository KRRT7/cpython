Contributing to Python
======================

Build Status
------------

- `Buildbot status overview <https://buildbot.python.org/#/release_status>`_
- `GitHub Actions status <https://github.com/python/cpython/actions/workflows/build.yml>`_


Thank You
---------
Thanks for contributing to the maintenance of the Python programming language
and the CPython interpreter! Even if your contribution is not ultimately
accepted, the fact you put time and effort into helping out is greatly
appreciated.


Understanding the Workflow
--------------------------

**Target branch.** Almost all changes — including bug fixes — should be made
against the ``main`` branch first. After merging, backports to maintenance
branches are handled by the core team.

**No force-pushes on open pull requests.** Once a pull request is open, do not
squash, amend, or rebase your branch. Reviewers follow individual commits to
track what has changed; the PR will be squash-merged into a single commit on
acceptance.

**Bots and status checks.** Automated bots comment on pull requests and run
status checks. Read their comments and follow the "Details" links for
failures — they are usually the fastest path to understanding what needs
fixing.

**Discuss in issues, not PR comments.** Conversations not directly about the
code in a pull request belong in the
`issue tracker <https://github.com/python/cpython/issues>`__, generally in the
pull request's parent issue.

**patchcheck.** Running ``make patchcheck`` (see `Running the Tests`_) confirms
that your change has tests, documentation updates, and a news entry where each
is required.

**Review timelines.** CPython is maintained by volunteers; there is no
guarantee of when a core developer will review your pull request. If a month
passes with no review, post in the `Core Development Discourse category
<https://discuss.python.org/c/core-dev/23>`__ to ask for a reviewer.

For a complete reference on the above, see the
`devguide <https://devguide.python.org/>`_.


Quick Start
-----------

To contribute without installing anything locally, use
`GitHub Codespaces <https://github.com/features/codespaces>`_:

1. Go to https://github.com/python/cpython.
2. Press ``,`` to open Codespaces setup, then click **Create new codespace**.
3. A browser-based VS Code opens with CPython already built and ready.

For a local setup, continue with the sections below.


Building CPython
----------------

Unix / macOS
^^^^^^^^^^^^

Install build dependencies (see the `devguide
<https://devguide.python.org/getting-started/setup-building/#install-dependencies>`_
for platform-specific package lists), then::

   $ ./configure --with-pydebug
   $ make -s -j$(nproc)                      # Linux
   $ make -s -j$(sysctl -n hw.logicalcpu)    # macOS

On macOS with Homebrew::

   $ brew bundle --file=Misc/Brewfile
   $ GDBM_CFLAGS="-I$(brew --prefix gdbm)/include" \
      GDBM_LIBS="-L$(brew --prefix gdbm)/lib -lgdbm" \
      ./configure --config-cache --with-pydebug \
                  --with-openssl="$(brew --prefix openssl@3)"
   $ make -s -j$(sysctl -n hw.logicalcpu)

The interpreter is available as ``./python`` (``./python.exe`` on
case-insensitive filesystems such as default macOS). No installation is
needed — Python finds its own files in the working copy.

Windows
^^^^^^^

.. code-block:: bat

   PCbuild\build.bat -c Debug

Run the result with ``PCbuild\amd64\python_d.exe``.
See ``PCbuild\readme.txt`` for required Visual Studio components.

Setting up pre-commit
^^^^^^^^^^^^^^^^^^^^^

::

   $ pre-commit install --allow-missing-config

Ruff, sphinx-lint, and several other checks will run automatically on every
``git commit``.


Running the Tests
-----------------

Run the full test suite from the root of your checkout after building:

.. code-block:: shell

   # Unix / macOS
   ./python -m test

   # Windows
   .\python.bat -m test

To run a single test file verbosely::

   ./python -m test -v test_abc

Run ``./python -m test -h`` to see all available options.

Before opening a pull request, also run ``patchcheck``:

.. code-block:: shell

   # Unix / macOS
   make patchcheck

   # Windows
   .\python.bat Tools\patchcheck\patchcheck.py


How to Submit a Pull Request
----------------------------

1. **Create a branch** from ``main``::

      git fetch upstream
      git checkout -b my-fix upstream/main

2. **Make your changes.** Follow PEP 8 for Python code and PEP 7 for C code
   (links in `Quick Reference`_). If you use AI tools, follow the
   `AI Policy <AI_POLICY.MD>`_.

3. **Add or update tests.** Pull requests without tests are unlikely to be
   accepted.

4. **Update documentation** in ``Doc/`` for any user-visible behavior change.

5. **Add a news entry** for non-trivial code changes (see `News Entries`_).

6. **Run the tests and patchcheck** (see `Running the Tests`_ above).

7. **Push and open a pull request**::

      git push origin my-fix

   Use the title format from `Quick Reference`_.


News Entries
------------

Most code changes need a news entry. Documentation-only, test-only, and
purely internal changes are exempt.

Use the ``blurb`` tool::

   pip install blurb
   blurb add

Or create the file manually — see `Quick Reference`_ for the filename format
and list of subdirectories.

Write a short, user-facing reStructuredText description. Example::

   Fix :func:`os.path.join` to handle drive-relative paths on Windows.
   Contributed by Jane Smith.


Getting Help
------------

- `Core Development on Discourse <https://discuss.python.org/c/core-dev/23>`_ —
  general questions about contributing to CPython
- `Ideas on Discourse <https://discuss.python.org/c/ideas/6>`_ —
  to discuss new language or library ideas before writing code
- ``#python-dev`` on `Libera.Chat <https://libera.chat/>`_ — real-time chat
  with contributors and core developers
- `Python Mentors <https://www.python.org/dev/core-mentorship/>`_ — volunteer
  mentors for new contributors


Quick Reference
---------------

**PR title**

.. code-block:: text

   gh-NNNNNN: Brief description of the change

Trivial changes (typo fixes, etc.) do not need an issue number.

**Backport PR title**

.. code-block:: text

   [X.Y] Brief description of the change (GH-NNNNNN)

``[X.Y]`` is the branch name (e.g. ``[3.13]``); ``GH-NNNNNN`` is the original
PR number from ``main``.

Use the backport template by appending ``?template=backport.md`` when opening
the PR on GitHub.

**News entry path**

.. code-block:: text

   Misc/NEWS.d/next/<category>/YYYY-MM-DD-hh-mm-ss.gh-issue-NNNNN.<nonce>.rst

Available categories: ``Library``, ``Core_and_Builtins``, ``C_API``,
``Documentation``, ``Tests``, ``Build``, ``Windows``, ``macOS``,
``Tools-Demos``, ``IDLE``, ``Security``.

**Style guides:** `PEP 8 <https://peps.python.org/pep-0008/>`_ (Python),
`PEP 7 <https://peps.python.org/pep-0007/>`_ (C)

**Linting:** Ruff and sphinx-lint via pre-commit.
Install once per clone with ``pre-commit install --allow-missing-config``.

**AI tools:** See `AI Policy <AI_POLICY.MD>`_.

**Full contributor docs:** `devguide <https://devguide.python.org/>`_


Reporting Security Issues
-------------------------

Please **do not** report security vulnerabilities through public GitHub issues.
See `SECURITY.md <SECURITY.md>`_ for how to responsibly disclose a security
problem to the Python security response team.
