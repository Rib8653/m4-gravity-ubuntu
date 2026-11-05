# Mesa packaging overrides

Files here are copied over Ubuntu's `debian/` directory before the build, for
example a fixed `debian/libgl1-mesa-dri.install` when Gravity's newer Mesa
installs files that Ubuntu's 26.0 packaging does not expect.

Use the same relative paths as inside `debian/`. This README itself is copied
too, which does no harm.
