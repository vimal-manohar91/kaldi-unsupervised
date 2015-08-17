#!/bin/bash 
#

if [ -f path.sh ]; then . path.sh; fi

lmdir=data/local/lm
lang=data/lang_test
arpa_lm=$lmdir/3gram-mincount/lm_unpruned.gz
src_lang=data/lang

. parse_options.sh

# local/fisher_create_small_test_lang --lmdir data/local/lm_bg --arpa-lm data/local/lm_bg/srilm.o2g.kn.gz

mkdir -p $lang

[ ! -f $arpa_lm ] && echo No such file $arpa_lm && exit 1;

cp -rT ${src_lang} $lang

# grep -v '<s> <s>' etc. is only for future-proofing this script.  Our
# LM doesn't have these "invalid combinations".  These can cause 
# determinization failures of CLG [ends up being epsilon cycles].
# Note: remove_oovs.pl takes a list of words in the LM that aren't in
# our word list.  Since our LM doesn't have any, we just give it
# /dev/null [we leave it in the script to show how you'd do it].
gunzip -c "$arpa_lm" | \
   grep -v '<s> <s>' | \
   grep -v '</s> <s>' | \
   grep -v '</s> </s>' | \
   arpa2fst - | fstprint | \
   utils/remove_oovs.pl /dev/null | \
   utils/eps2disambig.pl | utils/s2eps.pl | fstcompile --isymbols=$lang/words.txt \
     --osymbols=$lang/words.txt  --keep_isymbols=false --keep_osymbols=false | \
    fstrmepsilon | fstarcsort --sort_type=ilabel > $lang/G.fst
  fstisstochastic $lang/G.fst


echo  "Checking how stochastic G is (the first of these numbers should be small):"
fstisstochastic $lang/G.fst 

## Check lexicon.
## just have a look and make sure it seems sane.
echo "First few lines of lexicon FST:"
fstprint   --isymbols=${src_lang}/phones.txt --osymbols=${src_lang}/words.txt ${src_lang}/L.fst  | head

echo Performing further checks

# Checking that G.fst is determinizable.
fstdeterminize $lang/G.fst /dev/null || echo Error determinizing G.

# Checking that L_disambig.fst is determinizable.
fstdeterminize $lang/L_disambig.fst /dev/null || echo Error determinizing L.

# Checking that disambiguated lexicon times G is determinizable
# Note: we do this with fstdeterminizestar not fstdeterminize, as
# fstdeterminize was taking forever (presumbaly relates to a bug
# in this version of OpenFst that makes determinization slow for
# some case).
fsttablecompose $lang/L_disambig.fst $lang/G.fst | \
   fstdeterminizestar >/dev/null || echo Error

# Checking that LG is stochastic:
fsttablecompose ${src_lang}/L_disambig.fst $lang/G.fst | \
   fstisstochastic || echo "[log:] LG is not stochastic"


echo "$0 succeeded"

