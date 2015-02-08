#!/bin/bash

# Copyright     2013  Daniel Povey
# Apache 2.0.


# This script computes iVectors in the same format as extract_ivectors_online.sh,
# except that they are actually not really computed online, they are first computed
# per speaker and just duplicated many times.
#
# This setup also makes it possible to use a previous decoding or alignment, to
# down-weight silence in the stats (default is --silence-weight 0.0).
#
# This is for when you use the "online-decoding" setup in an offline task, and
# you want the best possible results.  


# Begin configuration section.
nj=30
cmd="run.pl"
stage=0
num_gselect=5 # Gaussian-selection using diagonal model: number of Gaussians to select
min_post=0.025 # Minimum posterior to use (posteriors below this are pruned out)
ivector_period=10
posterior_scale=0.1 # Scale on the acoustic posteriors, intended to account for
                    # inter-frame correlations.  Making this small during iVector
                    # extraction is equivalent to scaling up the prior, and will
                    # will tend to produce smaller iVectors where data-counts are
                    # small.  It's not so important that this match the value
                    # used when training the iVector extractor, but more important
                    # that this match the value used when you do real online decoding
                    # with the neural nets trained with these iVectors.
max_count=100       # Interpret this as a number of frames times posterior scale...
                    # this config ensures that once the count exceeds this (i.e.
                    # 1000 frames, or 10 seconds, by default), we start to scale
                    # down the stats, accentuating the prior term.   This seems quite
                    # important for some reason.
compress=true       # If true, compress the iVectors stored on disk (it's lossy
                    # compression, as used for feature matrices).
silence_weight=0.0
acwt=0.1  # used if input is a decode dir, to get best path from lattices.
mdl=final  # change this if decode directory did not have ../final.mdl present.

# End configuration section.

echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;


if [ $# != 4 ] && [ $# != 5 ]; then
  echo "Usage: $0 [options] <data> <lang> <extractor-dir> [<alignment-dir>|<decode-dir>] <ivector-dir>"
  echo " e.g.: $0 data/test exp/nnet2_online/extractor exp/tri3/decode_test exp/nnet2_online/ivectors_test"
  echo "main options (for others, see top of script file)"
  echo "  --config <config-file>                           # config containing options"
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --nj <n|10>                                      # Number of jobs (also see num-processes and num-threads)"
  echo "                                                   # Ignored if <alignment-dir> or <decode-dir> supplied."
  echo "  --stage <stage|0>                                # To control partial reruns"
  echo "  --num-gselect <n|5>                              # Number of Gaussians to select using"
  echo "                                                   # diagonal model."
  echo "  --min-post <float;default=0.025>                 # Pruning threshold for posteriors"
  echo "  --ivector-period <int;default=10>                # How often to extract an iVector (frames)"
  echo "  --utts-per-spk-max <int;default=-1>   # Controls splitting into 'fake speakers'."
  echo "                                        # Set to 1 if compatibility with utterance-by-utterance"
  echo "                                        # decoding is the only factor, and to larger if you care "
  echo "                                        # also about adaptation over several utterances."
  exit 1;
fi

if [ $# -eq 4 ]; then
  data=$1
  lang=$2
  srcdir=$3
  dir=$4
else # 5 arguments
  data=$1
  lang=$2
  srcdir=$3
  ali_or_decode_dir=$4
  dir=$5
fi

for f in $data/feats.scp $srcdir/final.ie $srcdir/final.dubm $srcdir/global_cmvn.stats $srcdir/splice_opts \
  $lang/phones.txt $srcdir/online_cmvn.conf $srcdir/final.mat; do
  [ ! -f $f ] && echo "$0: No such file $f" && exit 1;
done

mkdir -p $dir/log 
silphonelist=$(cat $lang/phones/silence.csl) || exit 1;

if [ ! -z "$ali_or_decode_dir" ]; then

  nj_orig=$(cat $ali_or_decode_dir/num_jobs) || exit 1;
  
  if [ -f $ali_or_decode_dir/ali.1.gz ]; then
    if [ ! -f $ali_or_decode_dir/${mdl}.mdl ]; then
      echo "$0: expected $ali_or_decode_dir/${mdl}.mdl to exist."
      exit 1;
    fi

    if [ $stage -le 0 ]; then
      rm $dir/weights.*.gz 2>/dev/null

      $cmd JOB=1:$nj_orig  $dir/log/ali_to_post.JOB.log \
        gunzip -c $ali_or_decode_dir/ali.JOB.gz \| \
        ali-to-post ark:- ark:- \| \
        weight-silence-post $silence_weight $silphonelist $ali_or_decode_dir/final.mdl ark:- ark:- \| \
        post-to-weights ark:- "ark:|gzip -c >$dir/weights.JOB.gz" || exit 1;

      # put all the weights in one archive.
      for j in $(seq $nj_orig); do gunzip -c $dir/weights.$j.gz; done | gzip -c >$dir/weights.gz || exit 1;
      rm $dir/weights.*.gz || exit 1;
    fi

  elif [ -f $ali_or_decode_dir/lat.1.gz ]; then
    if [ ! -f $ali_or_decode_dir/../${mdl}.mdl ]; then
      echo "$0: expected $ali_or_decode_dir/../${mdl}.mdl to exist."
      exit 1;
    fi


    if [ $stage -le 0 ]; then
      rm $dir/weights.*.gz 2>/dev/null

      $cmd JOB=1:$nj_orig  $dir/log/lat_to_post.JOB.log \
        lattice-best-path --acoustic-scale=$acwt "ark:gunzip -c $ali_or_decode_dir/lat.JOB.gz|" ark:/dev/null ark:- \| \
        ali-to-post ark:- ark:- \| \
        weight-silence-post $silence_weight $silphonelist $ali_or_decode_dir/../${mdl}.mdl ark:- ark:- \| \
        post-to-weights ark:- "ark:|gzip -c >$dir/weights.JOB.gz" || exit 1;

      # put all the weights in one archive.
      for j in $(seq $nj_orig); do gunzip -c $dir/weights.$j.gz; done | gzip -c >$dir/weights.gz || exit 1;
      rm $dir/weights.*.gz || exit 1;
    fi
  else
    echo "$0: expected ali.1.gz or lat.1.gz to exist in $ali_or_decode_dir";
    exit 1;
  fi

fi

# Now work out the per-speaker iVectors.

sdata=$data/split$nj;
utils/split_data.sh $data $nj || exit 1;

echo $ivector_period > $dir/ivector_period || exit 1;
splice_opts=$(cat $srcdir/splice_opts)


gmm_feats="ark,s,cs:apply-cmvn-online --spk2utt=ark:$sdata/JOB/spk2utt --config=$srcdir/online_cmvn.conf $srcdir/global_cmvn.stats scp:$sdata/JOB/feats.scp ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $srcdir/final.mat ark:- ark:- |"
feats="ark,s,cs:splice-feats $splice_opts scp:$sdata/JOB/feats.scp ark:- | transform-feats $srcdir/final.mat ark:- ark:- |"


if [ $stage -le 1 ]; then
  if [ ! -z "$ali_or_decode_dir" ]; then
    $cmd JOB=1:$nj $dir/log/extract_ivectors.JOB.log \
      gmm-global-get-post --n=$num_gselect --min-post=$min_post $srcdir/final.dubm "$gmm_feats" ark:- \| \
      weight-post ark:- "ark,s,cs:gunzip -c $dir/weights.gz|" ark:- \| \
      ivector-extract --acoustic-weight=$posterior_scale --compute-objf-change=true \
        --max-count=$max_count --spk2utt=ark:$sdata/JOB/spk2utt \
      $srcdir/final.ie "$feats" ark,s,cs:- ark,t:$dir/ivectors_spk.JOB.ark || exit 1;
  else
    $cmd JOB=1:$nj $dir/log/extract_ivectors.JOB.log \
      gmm-global-get-post --n=$num_gselect --min-post=$min_post $srcdir/final.dubm "$gmm_feats" ark:- \| \
      ivector-extract --acoustic-weight=$posterior_scale --compute-objf-change=true \
        --max-count=$max_count --spk2utt=ark:$sdata/JOB/spk2utt \
      $srcdir/final.ie "$feats" ark,s,cs:- ark,t:$dir/ivectors_spk.JOB.ark || exit 1;
  fi
fi

# get an utterance-level set of iVectors (just duplicate the speaker-level ones).  
if [ $stage -le 2 ]; then
  for j in $(seq $nj); do 
    utils/apply_map.pl -f 2 $dir/ivectors_spk.$j.ark <$sdata/$j/utt2spk >$dir/ivectors_utt.$j.ark || exit 1;
  done
fi

ivector_dim=$[$(head -n 1 $dir/ivectors_spk.1.ark | wc -w) - 3] || exit 1;
echo  "$0: iVector dim is $ivector_dim"

base_feat_dim=$(feat-to-dim scp:$data/feats.scp -) || exit 1;

start_dim=$base_feat_dim
end_dim=$[$base_feat_dim+$ivector_dim-1]


if [ $stage -le 3 ]; then
  # here, we are just using the original features in $sdata/JOB/feats.scp for
  # their number of rows; we use the select-feats command to remove those
  # features and retain only the iVector features.
  $cmd JOB=1:$nj $dir/log/duplicate_feats.JOB.log \
    append-vector-to-feats scp:$sdata/JOB/feats.scp ark:$dir/ivectors_utt.JOB.ark ark:- \| \
    select-feats "$start_dim-$end_dim" ark:- ark:- \| \
    subsample-feats --n=$ivector_period ark:- ark:- \| \
    copy-feats --compress=$compress ark:- \
    ark,scp:$dir/ivector_online.JOB.ark,$dir/ivector_online.JOB.scp || exit 1;
fi

if [ $stage -le 4 ]; then
  echo "$0: combining iVectors across jobs"
  for j in $(seq $nj); do cat $dir/ivector_online.$j.scp; done >$dir/ivector_online.scp || exit 1;
fi

echo "$0: done extracting (pseudo-online) iVectors"
