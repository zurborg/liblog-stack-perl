use strictures 2;

package Log::Stack;

# ABSTRACT: Cache log messages and throw them later

use Moo;
use Carp qw(croak);
use Scalar::Util qw(blessed);

# VERSION

=head1 SYNOPSIS

    my $logger = Log::Stack->new($target);

    $logger->log($level => $message);

    # ...later:
    $logger->throw;
    # which simply calls $target->log(...) for each cached message

=cut

has _stack => (
    is => 'lazy',
    default => sub { [] },
    clearer => 1,
);

has _target => (
    is => 'ro',
);

has _defaults => (
    is => 'ro',
    default => sub { {} },
);

has _hooks => (
    is => 'ro',
    default => sub { {} },
);

has _initialized => (
    is => 'rw',
    default => 0,
);

sub _exechook {
    my ($self, $hook, @args) = @_;
    return unless $self->_hooks->{$hook};
    foreach my $code (@{ $self->_hooks->{$hook} }) {
        $code->($self, @args);
    }
}

=method new

    my $logger = Log::Stack->new($target, %defaults);

For C<$target> see L</"LOGGING TARGET">.

For C<%defaults> see L</"DEFAULT VALUES">.

Hint: C<$target> may be omitted, but then C</throw> requires a target at last.

=for Pod::Coverage BUILDARGS

=cut

sub BUILDARGS {
    my $class = shift;
    my ($target, %defaults);
    $target = shift if @_ % 2;
    %defaults = @_;
    return {
        _target => $target,
        _defaults => \%defaults,
    }
}

=method set

Set or override a default value for C<%extra_arguments> in L</log>

    $logger->set($key => $val);
    $logger->set($key1 => $val2, $key2 => $val2, ...);

See also L</"DEFAULT VALUES">.

=cut

sub set {
    my ($self, %vals) = @_;
    foreach my $key (keys %vals) {
        $self->_defaults->{$key} = delete $vals{$key};
    }
}

=method log

Cache a log message, with support for optional additional arguments

    $logger->log($level, $message, %extra_arguments);

See also L</"DEFAULT VALUES">.

=cut

sub log {
    my ($self, $level, $msg, %rest) = @_;
    unless ($self->_initialized) {
        $self->_exechook('init');
        $self->_initialized(1);
    }
    foreach my $key (keys %{ $self->_defaults }) {
        next if exists $rest{$key};
        my $val = $self->_defaults->{$key};
        if (ref $val eq 'CODE') {
            $rest{$key} = scalar($val->($level, $msg));
        } else {
            $rest{$key} = $val;
        }
    }
    push @{ $self->_stack } => [ $level, $msg, %rest ];
}

=method throw

Push all cached messages to the log target, specified in the constructor:

    $logger->throw;

If the target was absent in the constructor, this method requires the target at this point or it will croak:

    $logger->throw($target);

Or use another target, regardless of the target specified in the constructor:

    my $logger = Log::Stack->new($target1);
    # use here (and only here) another target:
    $logger->throw($target2);

If there are no cached messages, this method does almost nothing.

=cut

sub throw {
    my ($self, $target) = @_;
    return unless @{ $self->_stack };
    $target //= $self->_target;
    if (ref $target eq 'CODE') {
        $self->_exechook('before');
        while (my $msg = shift @{ $self->_stack }) {
            $target->(@$msg);
        }
        $self->_exechook('after');
    } elsif (blessed $target and $target->can('log')) {
        $self->_exechook('before');
        while (my $msg = shift @{ $self->_stack }) {
            $target->log(@$msg);
        }
        $self->_exechook('after');
    } else {
        croak "Logging target must be a blessed object with a log method or a CodeRref";
    }
    $self->_exechook('cleanup');
    $self->_initialized(0);
}

=method flush

Discard all cached messages.

    $logger->flush;

=cut

sub flush {
    my $self = shift;
    $self->_clear_stack;
    $self->_exechook('cleanup');
    $self->_initialized(0);
}

=method hook

    $logger->hook($name, $coderef);

Currently these hooks are defined:

=over 4

=item * init

Called when the first attemp to L</log> is made, even after L</throw> and L</flush>.

=item * before

Called in L</throw> when cached messages are available and before they are sent to the target.

=item * after

Called in L</throw> after cached messages are sent to the target.

=item * cleanup

Called in L</throw> and L</flush> after messages are sent or flushed.

=back

=cut

sub hook {
    my ($self, %def) = @_;
    foreach my $name (keys %def) {
        my $code = $def{$name};
        croak "Hook for $name must be a CodeRef" unless ref $code eq 'CODE';
        $self->_hooks->{$name} //= [];
        push @{ $self->_hooks->{$name} } => $code;
    }
}

=head1 DEFAULT VALUES

If logging defaults are defined, the C<%extra_arguments> hash in L</log> is filled with these defaults (specified in the constructor or later with L</set>).

Whenever a default value is a CodeRef, the CodeRef will be called with C<$level> and C<$message> as arguments:

    my $logger = Log::Stack->new($target,
        hint => sub {
            my ($level, $msg) = @_;
            return "the level is $level.";
        }
    );
    $logger->log(alert => "Caveat!");
    # The cached arguments are now:
    ('alert' => 'Caveat', 'hint' => 'the level is alert.');

This is useful for setting the I<real> timestamp:

    my $logger = Log::Stack->new($target,
        time => \&CORE::time,
    );

Or set an unique id in order to group messages together:

    $logger->set(id => get_some_random_number());
    $logger->log(...);
    $logger->throw;

    $logger->set(id => get_another_random_number());
    $logger->log(...);
    $logger->throw;

The defaults are NOT resseted after L</throw> or L</discard>. Use L<hook>s instead:

    $logger->hook(init => sub {
        shift->set(id => get_unique_id());
    });

=cut

=head1 LOGGING TARGET

The logging target must be a blessed reference which has a method called C<log> or simply a CodeRef. That's all.

This should apply to most logging engines, like L<Log::Log4perl>, L<Log::Dispatch>, L<Log::Radis>, L<AnyEvent::Log>, ...

For L<Log::Any> this CodeRef may help:

    $target = sub {
        my ($level, $msg) = @_;
        $log_any->$level($msg) if $log_any->can($level);
    };

=cut

1;
