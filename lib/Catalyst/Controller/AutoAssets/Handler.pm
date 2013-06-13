package Catalyst::Controller::AutoAssets::Handler;
use strict;
use warnings;

# VERSION

use Moose::Role;
use namespace::autoclean;

# REMOVE
use RapidApp::Include qw(sugar perlutil);

requires qw(
  asset_request
  write_built_file
);

use Path::Class 0.32 qw( dir file );
use Fcntl qw( :DEFAULT :flock :seek F_GETFL );
use File::stat qw(stat);
use Catalyst::Utils;
use Time::HiRes qw(gettimeofday tv_interval);
use Storable qw(store retrieve);
use Try::Tiny;

require Digest::SHA1;
require MIME::Types;
require Module::Runtime;

has '_Controller' => (
  is => 'ro', required => 1,
  isa => 'Catalyst::Controller::AutoAssets',
  handles => [qw(type _app action_namespace unknown_asset)],
);

# Directories to include
has 'include', is => 'ro', isa => 'Str|ArrayRef[Str]', required => 1;  

# Whether or not to make the current asset available via 307 redirect to the
# real, current checksum/fingerprint asset path
has 'current_redirect', is => 'ro', isa => 'Bool', default => sub{1};

# What string to use for the 'current' redirect
has 'current_alias', is => 'ro', isa => 'Str', default => sub { 'current' };

# Max number of seconds before recalculating the fingerprint (sha1 checksum)
# regardless of whether or not the mtime has changed. 0 means infinite/disabled
has 'max_fingerprint_calc_age', is => 'ro', isa => 'Int', default => sub {0};

# Max number of seconds to wait to obtain a lock (to be thread safe)
has 'max_lock_wait', is => 'ro', isa => 'Int', default => 120;

has 'cache_control_header', is => 'ro', isa => 'Str', 
  default => sub { 'public, max-age=31536000, s-max-age=31536000' }; # 31536000 = 1 year

# Whether or not to use stored state data across restarts to avoid rebuilding.
has 'persist_state', is => 'ro', isa => 'Bool', default => sub{0};

# Optional shorter checksum
has 'sha1_string_length', is => 'ro', isa => 'Int', default => sub{40};

# directory to use for relative includes (defaults to the Catalyst home dir);
# TODO: coerce from Str
has '_include_relative_dir', isa => 'Path::Class::Dir', is => 'ro', lazy => 1,
  default => sub { dir( (shift)->_app->config->{home} )->resolve };


######################################


sub BUILD {}
before BUILD => sub {
  my $self = shift;
  
  # optionally initialize state data from the copy stored on disk for fast
  # startup (avoids having to always rebuild after every app restart):
  $self->_restore_state if($self->persist_state);

  # init includes
  $self->includes;
  
  Catalyst::Exception->throw("Must include at least one file/directory")
    unless (scalar @{$self->includes} > 0);

  # if the user picks something lower than 5 it is probably a mistake (really, anything
  # lower than 8 is probably not a good idea. But the full 40 is probably way overkill)
  Catalyst::Exception->throw("sha1_string_length must be between 5 and 40")
    unless ($self->sha1_string_length >= 5 && $self->sha1_string_length <= 40);

  # init work_dir:
  $self->work_dir;
  
  $self->prepare_asset;
};

# Main code entry point:
sub request {
  my ( $self, $c, @args ) = @_;
  
  return $self->current_request($c, @args) if $self->is_current_request_arg(@args);
  return $self->asset_request($c,@args);
}

sub is_current_request_arg {
  my ($self, $arg) = @_;
  return $arg eq $self->current_alias ? 1 : 0;
}

sub current_request  {
  my ( $self, $c, $arg, @args ) = @_;

  my $path = $self->_valid_subpath($c,@args);
  $self->prepare_asset($path);

  $c->response->header( 'Cache-Control' => 'no-cache' );
  $c->response->redirect(join('/',$self->asset_path,@args), 307);
  return $c->detach;
}


############################


has 'work_dir', is => 'ro', isa => 'Path::Class::Dir', lazy => 1, default => sub {
  my $self = shift;
  my $c = $self->_app;
  
  my $tmpdir = Catalyst::Utils::class2tempdir($c)
    || Catalyst::Exception->throw("Can't determine tempdir for $c");
    
  my $dir = dir($tmpdir, "AutoAssets",  $self->action_namespace($c));
  $dir->mkpath($self->_app->debug);
  return $dir->resolve;
};

has 'built_file', is => 'ro', isa => 'Path::Class::File', lazy => 1, default => sub {
  my $self = shift;
  my $filename = 'built_file';
  return file($self->work_dir,$filename);
};

has 'fingerprint_file', is => 'ro', isa => 'Path::Class::File', lazy => 1, default => sub {
  my $self = shift;
  return file($self->work_dir,'fingerprint');
};

has 'lock_file', is => 'ro', isa => 'Path::Class::File', lazy => 1, default => sub {
  my $self = shift;
  return file($self->work_dir,'lockfile');
};

has 'work_dir', is => 'ro', isa => 'Path::Class::Dir', lazy => 1, default => sub {
  my $self = shift;
  my $c = $self->_app;
  
  my $tmpdir = Catalyst::Utils::class2tempdir($c)
    || Catalyst::Exception->throw("Can't determine tempdir for $c");
    
  my $dir = dir($tmpdir, "AutoAssets",  $self->action_namespace($c));
  $dir->mkpath($self->_app->debug);
  return $dir->resolve;
};



has 'includes', is => 'ro', isa => 'ArrayRef', lazy => 1, default => sub {
  my $self = shift;
  my $rel = $self->_include_relative_dir;
  my @list = ref $self->include ? @{$self->include} : $self->include;
  return [ map {
    my $inc = file($_);
    $inc = $rel->file($inc) unless ($inc->is_absolute);
    $inc = dir($inc) if (-d $inc); #<-- convert to Path::Class::Dir
    $inc->resolve
  } @list ];
};

sub get_include_files { 
  my $self = shift;
  
  my @files = ();
  for my $inc (@{$self->includes}) {
    if($inc->is_dir) {
      $inc->recurse(
        preorder => 1,
        depthfirst => 1,
        callback => sub {
          my $child = shift;
          push @files, $child->absolute unless ($child->is_dir);
        }
      );
    }
    else {
      push @files, $inc;
    }
  }
  
  # force consistent ordering of files:
  return [sort @files];
}

has 'last_fingerprint_calculated', is => 'rw', isa => 'Maybe[Int]', default => sub{undef};

has 'built_mtime', is => 'rw', isa => 'Maybe[Str]', default => sub{undef};
sub get_built_mtime {
  my $self = shift;
  return -f $self->built_file ? $self->built_file->stat->mtime : undef;
}

# inc_mtimes are the mtime(s) of the include files. For directory assets
# this is *only* the mtime of the top directory (see subfile_meta below)
has 'inc_mtimes', is => 'rw', isa => 'Maybe[Str]', default => undef;
sub get_inc_mtime_concat {
  my $self = shift;
  my $list = shift;
  return join('-', map { $_->stat->mtime } @$list );
}


sub calculate_fingerprint {
  my $self = shift;
  my $list = shift;
  # include both the include (source) and built (output) in the fingerprint:
  my $sha1 = $self->file_checksum(@$list,$self->built_file);
  $self->last_fingerprint_calculated(time) if ($sha1);
  return $sha1;
}

sub current_fingerprint {
  my $self = shift;
  return undef unless (-f $self->fingerprint_file);
  my $fingerprint = $self->fingerprint_file->slurp;
  return $fingerprint;
}

sub save_fingerprint {
  my $self = shift;
  my $fingerprint = shift or die "Expected fingerprint/checksum argument";
  return $self->fingerprint_file->spew($fingerprint);
}

sub calculate_save_fingerprint {
  my $self = shift;
  my $fingerprint = $self->calculate_fingerprint(@_) or return 0;
  return $self->save_fingerprint($fingerprint);
}

sub fingerprint_calc_current {
  my $self = shift;
  my $last = $self->last_fingerprint_calculated or return 0;
  return 1 if ($self->max_fingerprint_calc_age == 0); # <-- 0 means infinite
  return 1 if (time - $last < $self->max_fingerprint_calc_age);
  return 0;
}

# -----
# Quick and dirty state persistence for faster startup
has 'persist_state_file', is => 'ro', isa => 'Path::Class::File', lazy => 1, default => sub {
  my $self = shift;
  return file($self->work_dir,'state.dat');
};

has '_persist_attrs', is => 'ro', isa => 'ArrayRef', default => sub{[qw(
 built_mtime
 inc_mtimes
 last_fingerprint_calculated
)]};

sub _persist_state {
  my $self = shift;
  return undef unless ($self->persist_state);
  my $data = { map { $_ => $self->$_ } @{$self->_persist_attrs} };
  store $data, $self->persist_state_file;
  return $data;
}

sub _restore_state {
  my $self = shift;
  return 0 unless (-f $self->persist_state_file);
  my $data;
  try {
    $data = retrieve $self->persist_state_file;
    $self->$_($data->{$_}) for (@{$self->_persist_attrs});
  }
  catch {
    $self->clear_asset; #<-- make sure no partial state data is used
    $self->_app->log->warn(
      'Failed to restore state from ' . $self->persist_state_file
    );
  };
  return $data;
}
# -----


# force rebuild on next request/prepare_asset
sub clear_asset {
  my $self = shift;
  $self->inc_mtimes(undef);
}

sub _build_required {
  my ($self, $d) = @_;
  return (
    $self->inc_mtimes && $self->built_mtime &&
    $self->inc_mtimes eq $d->{inc_mtimes} &&
    $self->built_mtime eq $d->{built_mtime} &&
    $self->fingerprint_calc_current
  ) ? 0 : 1;
}


# Gets the data used throughout the prepare_asset process:
sub get_prepare_data {
  my $self = shift;
  
  my $files = $self->get_include_files;
  my $inc_mtimes = $self->get_inc_mtime_concat($files);
  my $built_mtime = $self->get_built_mtime;
  
  return {
    files => $files,
    inc_mtimes => $inc_mtimes,
    built_mtime => $built_mtime
  };
}

sub before_prepare_asset {}

sub prepare_asset {
  my $self = shift;
  my $start = [gettimeofday];

  # Optional hook:
  $self->before_prepare_asset(@_);

  my $d = $self->get_prepare_data;
  return 1 unless $self->_build_required($d);

  ####  -----
  ####  The code above this line happens on every request and is designed
  ####  to be as fast as possible
  ####
  ####  The code below this line is (comparatively) expensive and only
  ####  happens when a rebuild is needed which should be rare--only when
  ####  content is modified, or on app startup (unless 'persist_state' is set)
  ####  -----

  ### Do a rebuild:

  # --- Blocks for up to 2 minutes waiting to get an exclusive lock or dies
  $self->get_build_lock;
  # ---
  
  $self->build_asset($d);

  # Update the fingerprint (global) and cached mtimes (specific to the current process)
  $self->inc_mtimes($d->{inc_mtimes});
  $self->built_mtime($self->get_built_mtime);
  # we're calculating the fingerprint again because the built_file, which was just
  # regenerated, is included in the checksum data. This could probably be optimized,
  # however, this only happens on rebuild which rarely happens (should never happen)
  # in production so an extra second is no big deal in this case.
  $self->calculate_save_fingerprint($d->{files});

  $self->_app->log->info(
    "Built asset: " . $self->asset_path .
    ' in ' . sprintf("%.3f", tv_interval($start) ) . 's'
   );

  # Release the lock and return:
  $self->_persist_state;
  return $self->release_build_lock;
}


sub build_asset {
  my ($self, $opt) = @_;
  
  my $files = $opt->{files} || $self->get_include_files;
  my $inc_mtimes = $opt->{inc_mtimes} || $self->get_inc_mtime_concat($files);
  my $built_mtime = $opt->{inc_mtimes} || $self->get_built_mtime;
  
  # Check the fingerprint to see if we can avoid a full rebuild (if mtimes changed
  # but the actual content hasn't by comparing the fingerprint/checksum):
  my $fingerprint = $self->calculate_fingerprint($files);
  my $cur_fingerprint = $self->current_fingerprint;
  if($fingerprint && $cur_fingerprint && $cur_fingerprint eq $fingerprint) {
    # If the mtimes changed but the fingerprint matches we don't need to regenerate. 
    # This will happen if another process just built the files while we were waiting 
    # for the lock and on the very first time after the application starts up
    $self->inc_mtimes($inc_mtimes);
    $self->built_mtime($built_mtime);
    $self->_persist_state;
    return $self->release_build_lock;
  }

  ### Ok, we really need to do a full rebuild:
  
  my $fd = $self->built_file->openw or die $!;
  $self->write_built_file($fd,$files);
  $fd->close;
}

sub file_checksum {
  my $self = shift;
  my $files = ref $_[0] eq 'ARRAY' ? $_[0] : \@_;
  
  my $Sha1 = Digest::SHA1->new;
  foreach my $file ( grep { -f $_ } @$files ) {
    my $fh = $file->openr or die "$! : $file\n";
    $Sha1->addfile($fh);
    $fh->close;
  }

  return substr $Sha1->hexdigest, 0, $self->sha1_string_length;
}

sub asset_name { (shift)->current_fingerprint }

sub asset_path {
  my $self = shift;
  return '/' . $self->action_namespace($self->_app) . '/' . $self->asset_name;
}

# this is just used for some internal optimization to avoid calling stat
# duplicate times. It is basically me being lazy, adding an internal extra param
# to asset_path() without changing its public API/arg list
has '_asset_path_skip_prepare', is => 'rw', isa => 'Bool', default => 0;
before asset_path => sub {
  my $self = shift;
  $self->prepare_asset(@_) unless ($self->_asset_path_skip_prepare);
};

sub html_head_tags { undef }


sub get_build_lock_wait {
  my $self = shift;
  my $start = time;
  until($self->get_build_lock) {
    my $elapsed = time - $start;
    Catalyst::Exception->throw("AutoAssets: aborting waiting for lock after $elapsed")
      if ($elapsed >= $self->max_lock_wait);
    sleep 1;
  }
}

# TODO: find a lib that does this with better cross-platform support. This
# is only known to work under Linux
sub get_build_lock {
  my $self = shift;
  my $fname = $self->lock_file;
  sysopen(LOCKHANDLE, $fname, O_RDWR|O_CREAT|O_EXCL, 0644)
    or sysopen(LOCKHANDLE, $fname, O_RDWR)
    or die "Unable to create or open $fname\n";
  fcntl(LOCKHANDLE, F_SETFD, FD_CLOEXEC) or die "Failed to set close-on-exec for $fname";
  my $lockStruct= pack('sslll', F_WRLCK, SEEK_SET, 0, 0, $$);
  if (fcntl(LOCKHANDLE, F_SETLK, $lockStruct)) {
    my $data= "$$";
    syswrite(LOCKHANDLE, $data, length($data)) or die "Failed to write pid to $fname";
    truncate(LOCKHANDLE, length($data)) or die "Failed to resize $fname";
    # we do not close the file, so that we maintain the lock.
    return 1;
  }
  $self->release_build_lock;
  return 0;
}

sub release_build_lock {
  my $self = shift;
  close LOCKHANDLE;
}

1;
