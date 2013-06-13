package Catalyst::Controller::AutoAssets::Handler::JS;
use strict;
use warnings;

# VERSION

use Moose;
use namespace::autoclean;

extends 'Catalyst::Controller::AutoAssets::Handler::CSS';

use Module::Runtime;

has 'minifier', is => 'ro', isa => 'Maybe[CodeRef]', lazy => 1, default => sub {
  my $self = shift;
  Module::Runtime::require_module('JavaScript::Minifier');
  return sub { JavaScript::Minifier::minify(@_) };
};

has 'asset_content_type', is => 'ro', isa => 'Str', default => 'text/javascript';
has 'ext', is => 'ro', isa => 'Str', default => 'js';

sub html_head_tags {
  my $self = shift;
  return
		"<!--   AUTO GENERATED BY " . ref($self->_Controller) . " (/" .
    $self->action_namespace($self->_app) . ")   -->\r\n" .
		'<script type="text/javascript" src="' . 
    $self->asset_path .
    '"></script>' .
		"\r\n<!--  ---- END AUTO GENERATED ASSETS ----  -->\r\n";
}

1;