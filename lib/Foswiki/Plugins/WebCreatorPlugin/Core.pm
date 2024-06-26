# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# WebCreatorPlugin is Copyright (C) 2019-2024 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

package Foswiki::Plugins::WebCreatorPlugin::Core;

use strict;
use warnings;

use Foswiki::Func ();
use Foswiki::Form ();
use Foswiki::Plugins ();
use Error qw(:try);

use constant TRACE => 0; # toggle me

sub new {
  my $class = shift;
  my $session = shift || $Foswiki::Plugins::SESSION;

  my $this = bless({
    session => $session,
    @_
  }, $class);

  return $this;
}

sub finish {
  my $this = shift;

  undef $this->{session};
}

# params:
# - templateweb
# - parentweb
# - newweb
# - user
# - dry
# - UPPERCASE webPrefs
sub jsonRpcCreate {
  my ($this, $request) = @_;

  _writeDebug("called jsonRpcCreate");

  my $wikiName = Foswiki::Func::getWikiName();
  _writeDebug("wikiName=$wikiName");

  my $dry = Foswiki::Func::isTrue($request->param("dry"), 0);
  _writeDebug("dry run") if $dry;

  my $templateWeb = $request->param("templateweb") || "_default";
  _writeDebug("templateWeb=$templateWeb");

  throw Error::Simple("template web does not exist") unless Foswiki::Func::webExists($templateWeb);
  throw Error::Simple("access denied to template web") unless Foswiki::Func::checkAccessPermission("VIEW", $wikiName, undef, undef, $templateWeb);

  my $newWeb = $request->param("newweb");
  throw Error::Simple("no newweb parameter specified") unless $newWeb;

  my $parentWeb = $request->param("parentweb") || '';

  if ($parentWeb) {
    throw Error::Simple("parent web does not exist") unless Foswiki::Func::webExists($parentWeb);
    throw Error::Simple("access denied to parent web") unless Foswiki::Func::checkAccessPermission("VIEW", $wikiName, undef, undef, $parentWeb);

    $newWeb = "$parentWeb.$newWeb";
  }

  _writeDebug("newWeb=$newWeb");

  # expand autoinc
  if ($newWeb =~ /^(.*)AUTOINC(\d+)(.*)$/) {
    my $pre = $1 // '';
    my $start = $2;
    my $post = $3 // '';
    my $pad = length($start);

    foreach my $web (Foswiki::Func::getListOfWebs()) {
      $web =~ s/\//./g;
      next unless $web =~ /^\Q$pre\E(\d+)\Q$post\E$/;
      $start = $1 + 1 if $1 >= $start;
    }

    $newWeb = sprintf("$pre%0${pad}d$post", $start);
  }

  throw Error::Simple("invalid web name") unless Foswiki::Func::isValidWebName($newWeb, 1);

  my $overwrite = Foswiki::Func::isTrue($request->param("overwrite"), 0);
  _writeDebug("overwrite=$overwrite");

  throw Error::Simple("web already exists") if !$overwrite && Foswiki::Func::webExists($newWeb);

  # collect web preferences
  my $webPrefs = {
#   ALLOWWEBVIEW => $wikiName,
#   ALLOWWEBCHANGE => $wikiName,
#   ALLOWWEBRENAME => $wikiName,
#   ALLOWTOPICCHANGE => $wikiName
  };

  foreach my $key (keys %{$request->params()}) {
    next unless $key =~ /^[A-Z][A-Z_]*$/;
    my $v = $request->param($key);
    $webPrefs->{$key} = $v;
  }

  my $params = {
    source => $templateWeb, 
    target => $newWeb, 
    prefs => $webPrefs, 
    dry => $dry
  };

  my $error;

  # call index topic handlers
  $this->callBeforeCreaterWebHandler($params);

  try {
    $this->copyWeb($params);
  } catch Error with {
    $error = shift;
  };

  throw Error::Simple($error) if $error;

  $this->callAfterCreaterWebHandler($params);

  # return url of newly create web
  return {
    redirect => Foswiki::Func::getScriptUrl($newWeb, $Foswiki::cfg{HomeTopicName}, "view")
  };
}

# {
#   source => ...,
#   target => ...,
#   prefs => ...,
#   dry => ...
# }
sub copyWeb {
  my ($this, $params, $seen) = @_;


  $params->{source} =~ s/\./\//g;
  $params->{target} =~ s/\./\//g;
  $seen ||= {};

  return if $seen->{$params->{source}};
  $seen->{$params->{source}} = 1;

  _writeDebug("called copyWeb($params->{source}, $params->{target})");

  my $sourceObj = Foswiki::Meta->new($this->{session}, $params->{source});
  my $targetObj = Foswiki::Meta->new($this->{session}, $params->{target});

  unless (Foswiki::Func::topicExists($params->{target}, $Foswiki::cfg{WebPrefsTopicName})) {
    my $obj = $targetObj->new($this->{session}, $params->{target}, $Foswiki::cfg{WebPrefsTopicName}, "");
    $obj->save() unless $params->{dry};
  }

  my $it = $sourceObj->eachTopic();

  while ($it->hasNext()) {
    my $topic = $it->next();
    my $obj = Foswiki::Meta->load($this->{session}, $params->{source}, $topic);

    _writeDebug("copying topic $params->{source}.$topic to $params->{target}.$topic");

    # open attachment file handles
    my %attfh;
    foreach my $sfa ($obj->find('FILEATTACHMENT')) {
      my $fh = $obj->openAttachment($sfa->{name}, '<');
      _writeDebug("copying attachment $sfa->{name}");

      $attfh{$sfa->{name}} = {
        fh => $fh,
        date => $sfa->{date},
        user => $sfa->{user} || $this->{session}{user},
        comment => $sfa->{comment}
      };
    }

    # store other meta in WebHome
    if ($topic eq $Foswiki::cfg{HomeTopicName}) {
      $this->populateMeta($params, $obj);
    }

    # Item15136: need to set this early enough so that any beforeSaveHandler gets the right web ... required for Foswiki < 2.1.8
    $obj->{_web} = $params->{target}; # 

    $obj->save( # vs saveAs
      web => $params->{target},
      topic => $topic,
      forcenewrevision => 1
    ) unless $params->{dry};

    # copy file attachments
    while (my ($fa, $sfa) = each %attfh) {

      my $arev;
      $arev = $this->{session}{store}->saveAttachment(
        $obj, $fa,
        $sfa->{fh},
        $sfa->{user},
        {
          forcedate => $sfa->{date},
          minor => 1,
          comment => $sfa->{comment}
        }
      ) unless $params->{dry};

      close($sfa->{fh});
    }
  }

  # patch WebPreferences
  if ($params->{prefs}) {
    _writeDebug("processing WebPreferences");
    my ($sourcePrefsObj, $text) = Foswiki::Func::readTopic($params->{source}, $Foswiki::cfg{WebPrefsTopicName});
    my $targetPrefsObj = Foswiki::Meta->load($this->{session}, $params->{target}, $Foswiki::cfg{WebPrefsTopicName});

    $targetPrefsObj->copyFrom($sourcePrefsObj);

    my @bottomText = ();
    foreach my $key (keys %{$params->{prefs}}) {
      next if $key =~ /^_/;
      my $val = $params->{prefs}{$key};
      if (defined($val) && $val ne "") {

        if ($text =~ s/^((?:\t|   )+\*\s+)#?Set\s+$key\s*=.*?$/$1Set $key = $val/gm) {
          _writeDebug("patching text $key");
          # found in template
        } else {
          my $prefMeta = $targetPrefsObj->get("PREFERENCE", $key);
          if ($prefMeta) {
            _writeDebug("patching meta $key");
            $prefMeta->{value} = $val;
          } else {
            _writeDebug("appending $key");
            # not found, append it
            push @bottomText, "   * Set $key = $val";
          }
        }
      }
    }
    if (@bottomText) {
      $text .= "\n" unless $text =~ /\n$/;
      $text .= "\n---++ More Settings\n";
      $text .= join("\n", @bottomText)."\n";
    }

    $targetPrefsObj->text($text);
    $targetPrefsObj->save() unless $params->{dry};

    #if (TRACE) {
    #  _writeDebug("WebPreferences:".$targetPrefsObj->getEmbeddedStoreForm());
    #}
  }

  # update dbcache
  if (Foswiki::Func::getContext()->{DBCachePluginEnabled}) {
    _writeDebug("updating dbcache");
    require Foswiki::Plugins::DBCachePlugin;
    Foswiki::Plugins::DBCachePlugin::getDB($params->{target}, 2) unless $params->{dry};
  }

  my $sit = $sourceObj->eachWeb();
  while ( $sit->hasNext() ) {
    my $subWeb = $sit->next();
    my %subParams = %{$params};
    $subParams{source} = $params->{source} . '.' . $subWeb;
    $subParams{target} = $params->{target} . '.' . $subWeb;

    $this->callBeforeCreaterWebHandler(\%subParams);
    $this->copyWeb(\%subParams, $seen);
    $this->callAfterCreaterWebHandler(\%subParams);
  }
}

sub populateMeta {
  my ($this, $params, $obj) = @_;

  _writeDebug("called populateMeta for ".$obj->topic);

  my $request = Foswiki::Func::getRequestObject();

  my $formName = $obj->getFormName();
  return unless $formName;

  _writeDebug("formName=$formName");
  my ($web, $topic) = Foswiki::Func::normalizeWebTopicName($obj->web, $formName);
  my $formDef = Foswiki::Form->new($this->{session}, $web, $topic);

  foreach my $fieldDef (@{$formDef->getFields}) {
    my $name = $fieldDef->{name};
    _writeDebug("... testing params for $name");
    my $val = $params->{$name};
    if (defined $val) {
      _writeDebug("... found formfield value in params: $val");
      $request->param($name, $val);
    } else {
      _writeDebug("... not found");
    }
  }

  $formDef->getFieldValuesFromQuery($request, $obj);
}

sub callBeforeCreaterWebHandler {
  my ($this, $params) = @_;

  _writeDebug("calling before create web handler");
  my %seen;
  foreach my $sub (@Foswiki::Plugins::WebCreatorPlugin::beforeCreateWebHandler) {
    next if $seen{$sub};
    &$sub($this, $params);
    $seen{$sub} = 1;
  }
}

sub callAfterCreaterWebHandler {
  my ($this, $params) = @_;

  _writeDebug("calling after create web handler");
  my %seen;
  foreach my $sub (@Foswiki::Plugins::WebCreatorPlugin::afterCreateWebHandler) {
    next if $seen{$sub};
    &$sub($this, $params);
    $seen{$sub} = 1;
  }
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "WebCreatorPlugin::Core - $_[0]\n";
}

1;
