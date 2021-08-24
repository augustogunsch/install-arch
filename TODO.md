# install.sh
- Improve CLI (should have non-interactive mode)
- Add more colors

# Testing
- Test all possible combinations of system, distro and init system

# Code quality
- Improve code quality
- Maybe some functions like pacman_conf, set_locale should be made into actual scripts in other repos (they are useful and big)
- Put common (and maybe even exclusive) functions into a lib.sh file
- Make it as easy as possible to edit the script in the future
- Make a config.sh file, and add all paths to there (as well as other options)

# More systems
- Add support for the other init systems of Artix

# More automation
- Automate ALSA configuration
- Automatically install video cards drivers
- Better configure MIME types
