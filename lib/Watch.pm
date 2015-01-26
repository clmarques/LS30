#!/usr/bin/env perl
#   Copyright (C) 2010-2014, Nick Andrew <nick@nick-andrew.net>
#   Licensed under the terms of the GNU General Public License, Version 3
#
#  Alarm watching daemon

package Watch;

use strict;
use warnings;

use Data::Dumper qw(Dumper);

use ContactID::EventCode qw();
use LS30::DeviceSet qw();
use LS30::Log qw();
use LS30Command qw();
use LS30Connection qw();
use LS30::Decoder qw();
use Timer qw();

# Temporarily this is a class variable as the responder functions don't
# take a $self parameter.
my $devices;

sub new {
	my ($class, $server_address) = @_;

	if (!defined $server_address) {
		$server_address = $ENV{'LS30_SERVER'};
	}

	my $self = {
		server_address => $server_address,
		ls30c          => LS30Connection->new($server_address),
		pending        => '',
	};

	bless $self, $class;

	my $ls30c = $self->{ls30c};

	$ls30c->onConnectFail(sub {
		LS30::Log::error("Watch: Connection to $server_address failed, retrying");
		shift->retryConnect();
	});

	$ls30c->onDisconnect(sub {
		LS30::Log::error("Watch: Disconnected from $server_address, retrying");
		shift->retryConnect();
	});

	if (!$ls30c->connect()) {
		die "Unable to connect to server socket";
	}

	if (!$devices) {
		$devices = LS30::DeviceSet->new();
		$self->{devices} = $devices;
	}

	my $decoder = LS30::Decoder->new($self);

	$ls30c->setHandler($decoder);

	# Setup a disconnection retry timer, initially disabled
	$self->{timer2} = Timer->new(
		func_ref  => \&disc_timer_event,
		arg_ref   => ["timer2", $self, 0, 1], # name, self, time to wait, backoff
		next_time => undef,
	);

	return $self;
}

sub disc_timer_event {
	my ($ref) = @_;

	LS30::Log::error("Disconnected, retrying connect");
	my $self  = $ref->[1];
	my $ls30c = $self->{ls30c};
	my $timer = $self->{timer2};

	if (!$ls30c->connect()) {

		# Backoff try later
		if ($ref->[3] < 64) {
			$ref->[3] *= 2;
		}

		$ref->[2] += $ref->[3];
		LS30::Log::timePrint(sprintf("Connect failed, retry in %d sec", $ref->[3]));
		$timer->setNextTime($ref->[2]);
	} else {
		LS30::Log::timePrint("Connected");

		# Stop the timer
		$timer->stop();
	}
}

sub handleDeviceMessage {
	my ($self, $devmsg_obj) = @_;

	my $string        = $devmsg_obj->getString();
	my $event_name    = $devmsg_obj->getEventName();
	my $dev_type_name = $devmsg_obj->getDeviceType();
	my $device_id     = $devmsg_obj->getDeviceID();
	my $signal        = $devmsg_obj->getSignalStrength();
	my $unknown       = $devmsg_obj->getUnknown();

	my $ls30c = $self->{ls30c};

	my $device_ref = $self->{devices}->findDeviceByCode($device_id);
	my $device_name;

	if (!$device_ref) {
		$device_name = 'Unknown';
	} else {
		$device_name = $device_ref->{'zone'} . ' ' . $device_ref->{'name'};
	}

	my $concat = join(' ', $string, $event_name, $dev_type_name, "$device_id $device_name", "signal $signal", ($unknown ? $unknown : ''));
	LS30::Log::timePrint($concat);
}

sub handleEventMessage {
	my ($self, $evmsg_obj) = @_;

	my $text = $evmsg_obj->asText();
	LS30::Log::timePrint($text);
}

sub handleResponse {
	my ($self, $line) = @_;

	my $resp_hr = LS30Command::parseResponse($line);

	if (!$resp_hr) {
		LS30::Log::error("Received unexpected response $line");
		return;
	}

	my $s = sprintf("Response: %s (%s)", $resp_hr->{title}, $resp_hr->{value});
	LS30::Log::timePrint($s);
}

sub handleResponseMessage {
	my ($self, $response_obj) = @_;

	if (!$response_obj) {
		LS30::Log::error("Received unexpected response");
		return;
	}

	if ($response_obj->{error}) {
		my $s = sprintf("Response: ", $response_obj->{error});
		LS30::Log::timePrint($s);
	} else {
		my $value = $response_obj->{value};
		$value = '' if (!defined $value);
		my $title = $response_obj->{title} || 'Unknown';
		my $s = sprintf("Response: %s (%s)", $title, $value);
		LS30::Log::timePrint($s);
	}

	print Data::Dumper::Dumper($response_obj);
}

sub handleAT {
	my ($self, $line) = @_;

	LS30::Log::timePrint("Ignoring AT: $line");
}

sub handleGSM {
	my ($self, $line) = @_;

	LS30::Log::timePrint("Ignoring GSM: $line");
}

1;
