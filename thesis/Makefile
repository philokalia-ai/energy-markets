# Thesis Makefile
# ================
#
# Required packages (Ubuntu/Debian):
#   sudo apt install texlive-xetex texlive-lang-greek texlive-fonts-extra
#   sudo apt install fonts-liberation ttf-mscorefonts-installer
#   sudo apt install latexmk
#   pip install Pygments  # For minted code highlighting
#
# Usage:
#   make          # Build thesis.pdf
#   make clean    # Remove auxiliary files
#   make distclean # Remove all generated files including PDF

.PHONY: FORCE default clean distclean

FILE = thesis

export SHELL = /bin/bash
export TEXINPUTS := .:./Styles//:${TEXINPUTS}
export BSTINPUTS := .:./Styles//:${BSTINPUTS}

default: $(FILE).pdf

# Using -shell-escape because of the package "minted" for typesetting
# listings of code. Remove if not needed.
%.pdf: %.tex FORCE
	latexmk -shell-escape -pdf -f -e '$$pdflatex=q/xelatex %O %S/' $<

clean:
	$(RM) *.{dvi,aux,log,toc,lof,lol,lot,dlog,bbl,blg,idx,out,tpt,svn}
	$(RM) *.{nav,snm,vrb,fls,fdb_latexmk} *~ *.bak
	$(RM) -r _minted-thesis/

distclean: clean
	$(RM) $(FILE).{dvi,ps,pdf}
