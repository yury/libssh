/*
 * socket.c - socket functions for the library
 *
 * This file is part of the SSH Library
 *
 * Copyright (c) 2008-2010      by Aris Adamantiadis
 *
 * The SSH Library is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at your
 * option) any later version.
 *
 * The SSH Library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
 * License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with the SSH Library; see the file COPYING.  If not, write to
 * the Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
 * MA 02111-1307, USA.
 */

#include "config.h"

#include <errno.h>
#include <stdio.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#if _MSC_VER >= 1400
#include <io.h>
#undef open
#define open _open
#undef close
#define close _close
#undef read
#define read _read
#undef write
#define write _write
#endif /* _MSC_VER */
#else /* _WIN32 */
#include <fcntl.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#endif /* _WIN32 */

#include "libssh/priv.h"
#include "libssh/callbacks.h"
#include "libssh/socket.h"
#include "libssh/buffer.h"
#include "libssh/poll.h"
#include "libssh/session.h"

#include <Foundation/Foundation.h>
#include <netinet/in.h>
#include <netinet/tcp.h>


/**
 * @internal
 *
 * @defgroup libssh_socket The SSH socket functions.
 * @ingroup libssh
 *
 * Functions for handling sockets.
 *
 * @{
 */

enum ssh_socket_states_e {
	SSH_SOCKET_NONE,
	SSH_SOCKET_CONNECTING,
	SSH_SOCKET_CONNECTED,
	SSH_SOCKET_EOF,
	SSH_SOCKET_ERROR,
	SSH_SOCKET_CLOSED
};

struct ssh_socket_struct {
  socket_t fd;
  int fd_is_socket;
  int last_errno;
  int data_except;
  enum ssh_socket_states_e state;
  ssh_session session;
  ssh_socket_callbacks callbacks;
#ifdef HAVE_DISPATCH_H
  void *io;
#else
  int read_wontblock; /* reading now on socket will
                       not block */
  int write_wontblock;
  ssh_buffer in_buffer;
  ssh_buffer out_buffer;
  ssh_poll_handle poll_handle;
#endif
};

@interface IO: NSObject <NSStreamDelegate>
- (int)wait:(int)milliseconds;
- (NSInteger)write:(const uint8_t *)buffer maxLength:(NSUInteger)len;
- (int)connectToHost:(NSString *)host andPort:(int)port;
- (int)connectedWithInFd:(int)fdIn fdOut:(int)fdOut;
@end

@implementation IO {
  NSMutableData *_out_data;
  NSMutableData *_in_data;

  NSInputStream *_inputStream;
  NSOutputStream *_outputStream;
  ssh_socket _ssh_socket;

  CFSocketRef _in_sock_ref;
  CFRunLoopSourceRef _in_source_ref;
  dispatch_fd_t _out_fd;
}

- (instancetype) initWithSSHSocket:(ssh_socket) ssh_socket {
  if (self = [super init]) {
    _ssh_socket = ssh_socket;
    _out_data = [[NSMutableData alloc] init];
    _in_data = [[NSMutableData alloc] init];
    _out_fd = SSH_INVALID_SOCKET;
  }
  return self;
}

- (void) close {
  if (_outputStream != nil || _inputStream != nil) {
    [_outputStream close];
    [_inputStream close];

    [_inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [_outputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];

    [_outputStream setDelegate: nil];
    [_inputStream setDelegate: nil];


    CFRelease(_outputStream);
    CFRelease(_inputStream);

    _outputStream = nil;
    _inputStream = nil;
  }

  if (_in_source_ref) {
    CFRunLoopSourceInvalidate(_in_source_ref);
    CFRelease(_in_source_ref);
    _in_source_ref = NULL;
  }
  if (_in_sock_ref) {
		CFSocketInvalidate(_in_sock_ref);
		CFRelease(_in_sock_ref);
		_in_sock_ref = NULL;
	}

  if (_out_fd != SSH_INVALID_SOCKET) {
    close(_out_fd);
    _out_fd = SSH_INVALID_SOCKET;
  }
}

- (void)dealloc {
  [self close];
}

void __in_sock_callback(CFSocketRef sock, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
  IO *io = (__bridge IO*)info;
  ssh_socket s = io->_ssh_socket;
  switch (type) {
    case kCFSocketReadCallBack: {
      const int BUFFER_SIZE = 4096 * 8;
      uint8_t buffer[BUFFER_SIZE] = {0};

      ssize_t len = read(CFSocketGetNative(sock), buffer, BUFFER_SIZE);
      if (len == 0) { // EOF
        if (io->_in_data.length > 0) {
          [io _process_in_data];
        }
        // EOF
        if (s->callbacks && s->callbacks->exception) {
          s->callbacks->exception(SSH_SOCKET_EXCEPTION_EOF,
                                  0, s->callbacks->userdata);
        }
        return;
      } else if (len < 0) {
        // try again
        return;
      }

      [io->_in_data appendBytes:buffer length:len];

      [io _process_in_data];
    }
      break;

    default:
      break;
  }
}

- (int)connectedWithInFd:(int)fdIn fdOut:(int)fdOut {
    CFSocketContext ctx = {.info = (__bridge void*)self};
    _in_sock_ref = CFSocketCreateWithNative(NULL, fdIn, kCFSocketReadCallBack, __in_sock_callback, &ctx);

    _in_source_ref = CFSocketCreateRunLoopSource(NULL, _in_sock_ref, 0);
    _out_fd = fdOut;
    CFRunLoopAddSource(CFRunLoopGetCurrent(), _in_source_ref, kCFRunLoopDefaultMode);

    return SSH_OK;
}

- (int)connectToHost:(NSString *)host andPort:(int)port {
  NSRunLoop *runLoop = [NSRunLoop currentRunLoop];

  CFReadStreamRef readStream;
  CFWriteStreamRef writeStream;

  CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)host, port, &readStream, &writeStream);
  _inputStream = (__bridge_transfer NSInputStream *)readStream;
  _outputStream = (__bridge_transfer NSOutputStream *)writeStream;

  if (_inputStream == nil || _outputStream == nil) {
    return SSH_ERROR;
  }

  [_inputStream setDelegate:self];
  [_outputStream setDelegate:self];

  _ssh_socket->state = SSH_SOCKET_CONNECTING;

  [_inputStream scheduleInRunLoop:runLoop forMode:NSDefaultRunLoopMode];
  [_outputStream scheduleInRunLoop:runLoop forMode:NSDefaultRunLoopMode];

  [_inputStream open];
  [_outputStream open];
  return SSH_AGAIN;
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode {
  ssh_socket s = _ssh_socket;
  if (stream == _inputStream) {
      switch (eventCode) {
          case NSStreamEventErrorOccurred:
              [self streamError: stream];
              // Exception for incoming messages.
              if (s->callbacks && s->callbacks->exception) {
                s->callbacks->exception(SSH_SOCKET_EXCEPTION_ERROR,
                                        s->last_errno, s->callbacks->userdata);
              }
              return;
          case NSStreamEventEndEncountered:
            // EOF
            if (s->callbacks && s->callbacks->exception) {
                s->callbacks->exception(SSH_SOCKET_EXCEPTION_EOF,
                                        0, s->callbacks->userdata);
            }
            return;
          case NSStreamEventHasBytesAvailable:
              [self _readin];
              return;
          default:
             NSLog(@"Blink: Unknown input event (%lu)", (unsigned long)eventCode);
             return;
      }
  }

  switch (eventCode) {
    case NSStreamEventOpenCompleted: {
     // Fetch a native handle to our socket
     CFDataRef nativeHandle = CFWriteStreamCopyProperty((CFWriteStreamRef) _outputStream, kCFStreamPropertySocketNativeHandle);
     if (nativeHandle) {
         s->fd = *(socket_t *)CFDataGetBytePtr(nativeHandle);
         CFRelease(nativeHandle);
     } else {
         NSLog(@"Blink: Unable to get socket file descriptor from stream. Breakage may occur.");
     }

     // Disable Nagle's algorithm
     if (s->fd != -1) {
         int val = 1;
         setsockopt(s->fd, IPPROTO_TCP, TCP_NODELAY, &val, sizeof(val));
         NSLog(@"Blink: TCP_NODELAY=1");
     }
      if (s->state == SSH_SOCKET_CONNECTING) {
        SSH_LOG(SSH_LOG_PACKET, "Received POLLOUT in connecting state");
        s->state = SSH_SOCKET_CONNECTED;
        if (s->callbacks && s->callbacks->connected) {
          s->callbacks->connected(SSH_SOCKET_CONNECTED_OK, 0,
                                  s->callbacks->userdata);
        }
        return;
      }
      }
      return;
    case NSStreamEventHasSpaceAvailable:
      [self _writeout];
      return;
    case NSStreamEventErrorOccurred:
        [self streamError: stream];
        if (s->callbacks && s->callbacks->exception) {
            s->callbacks->exception(SSH_SOCKET_EXCEPTION_ERROR,
                                    s->last_errno, s->callbacks->userdata);
        }
      return;
    default:
      NSLog(@"Blink: Unknown output event (%lu)", (unsigned long)eventCode);
      return;
  }
}

- (void)streamError:(NSStream *)stream {
  NSError *error = [stream streamError];
  _ssh_socket->last_errno = [error code];
}

- (int)wait:(int)milliseconds {
  NSDate * date;
  if (milliseconds <= 0) {
    date = [NSDate dateWithTimeIntervalSinceNow: 0.5];
  } else {
    date = [NSDate dateWithTimeIntervalSinceNow:milliseconds / 1000.0];
  }

  BOOL res = [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:date];
  if (res == NO) {
    return SSH_AGAIN;
  } else {
    return SSH_OK;
  }
}

- (NSInteger)write:(const uint8_t *)buffer maxLength:(NSUInteger)len {
  if (_out_data.length == 0) {
      if (len == 0) {
          return len;
      }
    [_outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
  }
  if (len > 0) {
      [_out_data appendBytes:buffer length:len];
  }
  if (_out_fd != SSH_INVALID_SOCKET) {
      int written = write(_out_fd, _out_data.bytes, _out_data.length);
      if (written > 0) {
        [_out_data replaceBytesInRange:NSMakeRange(0, written) withBytes:NULL length:0];
      }
      return written;
  }

  if (_outputStream.hasSpaceAvailable) {
      [self _writeout];
  }
  return len;
}

- (void)_writeout {
  __block NSInteger written = 0;
  [_out_data enumerateByteRangesUsingBlock:^(const void * _Nonnull bytes, NSRange byteRange, BOOL * _Nonnull stop) {
    NSInteger res = [_outputStream write:bytes maxLength:byteRange.length];
    if (res <= 0) {
      *stop = YES;
      return;
    }
    written += res;
    if (res != byteRange.length) {
      *stop = YES;
    }
  }];


  [_out_data replaceBytesInRange:NSMakeRange(0, written) withBytes:NULL length:0];
  if (_out_data.length == 0) {
    [_outputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
  }
}

- (void)_readin {
    const int BUFFER_SIZE = 4096 * 8;
    uint8_t buffer[BUFFER_SIZE] = {0};

    NSInteger len = [_inputStream read:buffer maxLength:BUFFER_SIZE];
    if (len <= 0) {
      // With -1 (ie timeout), it will go down and be captured later.
      return;
    }

    [_in_data appendBytes:buffer length:len];

    if (_in_data.length == 0) {
      return;
    }

    [self _process_in_data];
}

- (void)_process_in_data {
    int consumed = 0;
    int r = 0;
    ssh_socket s = _ssh_socket;
    if (!s->callbacks || !s->callbacks->data) {
        return;
    }
    NSInteger size = _in_data.length;
    // TODO: loop ranges
    const char * buffer = (char *) _in_data.bytes;
    if (size == 0) {
        return;
    }

    while (s->state == SSH_SOCKET_CONNECTED) {
        r = s->callbacks->data(buffer + consumed,
                size - consumed,
                s->callbacks->userdata);
        if ( r > 0) {
            consumed += r;
            continue;
        }
        break;
    }
    
    [_in_data replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
}

@end

static int sockets_initialized = 0;

static ssize_t ssh_socket_unbuffered_read(ssh_socket s,
                                          void *buffer,
                                          uint32_t len);
static ssize_t ssh_socket_unbuffered_write(ssh_socket s,
                                           const void *buffer,
                                           uint32_t len);

/**
 * \internal
 * \brief inits the socket system (windows specific)
 */
int ssh_socket_init(void) {
  if (sockets_initialized == 0) {
#ifdef _WIN32
    struct WSAData wsaData;

    /* Initiates use of the Winsock DLL by a process. */
    if (WSAStartup(MAKEWORD(2, 0), &wsaData) != 0) {
      return -1;
    }

#endif
    ssh_poll_init();

    sockets_initialized = 1;
  }

  return 0;
}

/**
 * @brief Cleanup the socket system.
 */
void ssh_socket_cleanup(void) {
  if (sockets_initialized == 1) {
    ssh_poll_cleanup();
#ifdef _WIN32
    WSACleanup();
#endif
    sockets_initialized = 0;
  }
}


/**
 * \internal
 * \brief creates a new Socket object
 */
ssh_socket ssh_socket_new(ssh_session session) {
  ssh_socket s;

  s = malloc(sizeof(struct ssh_socket_struct));
  if (s == NULL) {
    ssh_set_error_oom(session);
    return NULL;
  }
  s->fd = SSH_INVALID_SOCKET;
  s->last_errno = -1;
  s->fd_is_socket = 1;
  s->session = session;
  s->data_except = 0;
  s->state=SSH_SOCKET_NONE;
#if HAVE_DISPATCH_H
  s->io = (__bridge_retained void*)[[IO alloc] initWithSSHSocket:s];
#else
  s->read_wontblock = 0;
  s->write_wontblock = 0;
  s->in_buffer = ssh_buffer_new();
  if (s->in_buffer == NULL) {
    ssh_set_error_oom(session);
    SAFE_FREE(s);
    return NULL;
  }
  s->out_buffer=ssh_buffer_new();
  if (s->out_buffer == NULL) {
    ssh_set_error_oom(session);
    ssh_buffer_free(s->in_buffer);
    SAFE_FREE(s);
    return NULL;
  }
  s->data_except = 0;
  s->poll_handle = NULL;
#endif

  s->state=SSH_SOCKET_NONE;
  return s;
}

/**
 * @internal
 * @brief Reset the state of a socket so it looks brand-new
 * @param[in] s socket to rest
 */
void ssh_socket_reset(ssh_socket s){
  s->fd = SSH_INVALID_SOCKET;
  s->last_errno = -1;
  s->fd_is_socket = 1;
  s->data_except = 0;
#if HAVE_DISPATCH_H
  IO *io = (__bridge_transfer IO*)s->io;
  s->io = (__bridge_retained void*)[[IO alloc] initWithSSHSocket:s];
#else
  s->read_wontblock = 0;
  s->write_wontblock = 0;
  ssh_buffer_reinit(s->in_buffer);
  ssh_buffer_reinit(s->out_buffer);
  s->poll_handle = NULL;
#endif
  s->state=SSH_SOCKET_NONE;
}

/**
 * @internal
 * @brief the socket callbacks, i.e. callbacks to be called
 * upon a socket event.
 * @param s socket to set callbacks on.
 * @param callbacks a ssh_socket_callback object reference.
 */

void ssh_socket_set_callbacks(ssh_socket s, ssh_socket_callbacks callbacks){
	s->callbacks=callbacks;
}

#ifndef HAVE_DISPATCH_H
/**
 * @brief               SSH poll callback. This callback will be used when an event
 *                      caught on the socket.
 *
 * @param p             Poll object this callback belongs to.
 * @param fd            The raw socket.
 * @param revents       The current poll events on the socket.
 * @param userdata      Userdata to be passed to the callback function,
 *                      in this case the socket object.
 *
 * @return              0 on success, < 0 when the poll object has been removed
 *                      from its poll context.
 */
int ssh_socket_pollcallback(struct ssh_poll_handle_struct *p,
                            socket_t fd,
                            int revents,
                            void *v_s)
{
    ssh_socket s = (ssh_socket)v_s;
    char buffer[MAX_BUF_SIZE];
    ssize_t nread;
    int rc;
    int err = 0;
    socklen_t errlen = sizeof(err);

    /* Do not do anything if this socket was already closed */
    if (!ssh_socket_is_open(s)) {
        return -1;
    }
    SSH_LOG(SSH_LOG_TRACE, "Poll callback on socket %d (%s%s%s), out buffer %d",fd,
            (revents & POLLIN) ? "POLLIN ":"",
            (revents & POLLOUT) ? "POLLOUT ":"",
            (revents & POLLERR) ? "POLLERR":"",
            ssh_buffer_get_len(s->out_buffer));
    if (revents & POLLERR || revents & POLLHUP) {
        /* Check if we are in a connecting state */
        if (s->state == SSH_SOCKET_CONNECTING) {
            s->state = SSH_SOCKET_ERROR;
            rc = getsockopt(fd, SOL_SOCKET, SO_ERROR, (char *)&err, &errlen);
            if (rc < 0) {
                err = errno;
            }
            s->last_errno = err;
            ssh_socket_close(s);
            if (s->callbacks != NULL && s->callbacks->connected != NULL) {
                s->callbacks->connected(SSH_SOCKET_CONNECTED_ERROR,
                                        err,
                                        s->callbacks->userdata);
            }

            return -1;
        }
        /* Then we are in a more standard kind of error */
        /* force a read to get an explanation */
        revents |= POLLIN;
    }
    if ((revents & POLLIN) && s->state == SSH_SOCKET_CONNECTED) {
        s->read_wontblock = 1;
        nread = ssh_socket_unbuffered_read(s, buffer, sizeof(buffer));
        if (nread < 0) {
            if (p != NULL) {
                ssh_poll_remove_events(p, POLLIN);
            }

            if (s->callbacks != NULL && s->callbacks->exception != NULL) {
                s->callbacks->exception(SSH_SOCKET_EXCEPTION_ERROR,
                                        s->last_errno,
                                        s->callbacks->userdata);

                /* p may have been freed, so don't use it
                 * anymore in this function */
                p = NULL;
                return -2;
            }
        }
        if (nread == 0) {
            if (p != NULL) {
                ssh_poll_remove_events(p, POLLIN);
            }
            if (p != NULL) {
                ssh_poll_remove_events(p, POLLIN);
            }
            if (s->callbacks != NULL && s->callbacks->exception != NULL) {
                s->callbacks->exception(SSH_SOCKET_EXCEPTION_EOF,
                                        0,
                                        s->callbacks->userdata);

                /* p may have been freed, so don't use it
                 * anymore in this function */
                p = NULL;
                return -2;
            }
        }

        if (s->session->socket_counter != NULL) {
            s->session->socket_counter->in_bytes += nread;
        }

        /* Bufferize the data and then call the callback */
        rc = ssh_buffer_add_data(s->in_buffer, buffer, nread);
        if (rc < 0) {
            return -1;
        }
        if (s->callbacks != NULL && s->callbacks->data != NULL) {
            do {
                nread = s->callbacks->data(ssh_buffer_get(s->in_buffer),
                                       ssh_buffer_get_len(s->in_buffer),
                                       s->callbacks->userdata);
                ssh_buffer_pass_bytes(s->in_buffer, nread);
            } while ((nread > 0) && (s->state == SSH_SOCKET_CONNECTED));

            /* p may have been freed, so don't use it
             * anymore in this function */
            p = NULL;
        }
    }
#ifdef _WIN32
    if (revents & POLLOUT || revents & POLLWRNORM) {
#else
    if (revents & POLLOUT) {
#endif
        uint32_t len;

        /* First, POLLOUT is a sign we may be connected */
        if (s->state == SSH_SOCKET_CONNECTING) {
            SSH_LOG(SSH_LOG_PACKET, "Received POLLOUT in connecting state");
            s->state = SSH_SOCKET_CONNECTED;
            if (p != NULL) {
                ssh_poll_set_events(p, POLLOUT | POLLIN);
            }

            rc = ssh_socket_set_blocking(ssh_socket_get_fd(s));
            if (rc < 0) {
                return -1;
            }

            if (s->callbacks != NULL && s->callbacks->connected != NULL) {
                s->callbacks->connected(SSH_SOCKET_CONNECTED_OK,
                                        0,
                                        s->callbacks->userdata);
            }

            return 0;
        }

        /* So, we can write data */
        s->write_wontblock = 1;
        if (p != NULL) {
            ssh_poll_remove_events(p, POLLOUT);
        }

        /* If buffered data is pending, write it */
        len = ssh_buffer_get_len(s->out_buffer);
        if (len > 0) {
            ssh_socket_nonblocking_flush(s);
        } else if (s->callbacks != NULL && s->callbacks->controlflow != NULL) {
            /* Otherwise advertise the upper level that write can be done */
            SSH_LOG(SSH_LOG_TRACE,"sending control flow event");
            s->callbacks->controlflow(SSH_SOCKET_FLOW_WRITEWONTBLOCK,
                                      s->callbacks->userdata);
        }
        /* TODO: Find a way to put back POLLOUT when buffering occurs */
    }

    /* Return -1 if the poll handler disappeared */
    if (s->poll_handle == NULL) {
        return -1;
    }

    return 0;
}

#endif

/** @internal
 * @brief returns the poll handle corresponding to the socket,
 * creates it if it does not exist.
 * @returns allocated and initialized ssh_poll_handle object
 */
ssh_poll_handle ssh_socket_get_poll_handle(ssh_socket s)
{
#ifdef HAVE_DISPATCH_H
    return NULL;
#else
    if (s->poll_handle) {
        return s->poll_handle;
    }
    s->poll_handle = ssh_poll_new(s->fd,0,ssh_socket_pollcallback,s);
    return s->poll_handle;
#endif
}

/** \internal
 * \brief Deletes a socket object
 */
void ssh_socket_free(ssh_socket s){
  if (s == NULL) {
    return;
  }
  ssh_socket_close(s);
#ifdef HAVE_DISPATCH_H
  (__bridge_transfer IO*)s->io;
  s->io = NULL;
#else
  ssh_buffer_free(s->in_buffer);
  ssh_buffer_free(s->out_buffer);
#endif
  SAFE_FREE(s);
}

#ifndef _WIN32
int ssh_socket_unix(ssh_socket s, const char *path) {
  struct sockaddr_un sunaddr;
  socket_t fd;
  sunaddr.sun_family = AF_UNIX;
  snprintf(sunaddr.sun_path, sizeof(sunaddr.sun_path), "%s", path);

  fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd == SSH_INVALID_SOCKET) {
    ssh_set_error(s->session, SSH_FATAL,
		    "Error from socket(AF_UNIX, SOCK_STREAM, 0): %s",
		    strerror(errno));
    return -1;
  }

  if (fcntl(fd, F_SETFD, 1) == -1) {
    ssh_set_error(s->session, SSH_FATAL,
		    "Error from fcntl(fd, F_SETFD, 1): %s",
		    strerror(errno));
    close(fd);
    return -1;
  }

  if (connect(fd, (struct sockaddr *) &sunaddr,
        sizeof(sunaddr)) < 0) {
    ssh_set_error(s->session, SSH_FATAL, "Error from connect(): %s",
		    strerror(errno));
    close(fd);
    return -1;
  }
  ssh_socket_set_fd(s,fd);
  return 0;
}
#endif

/** \internal
 * \brief closes a socket
 */
void ssh_socket_close(ssh_socket s){

#if HAVE_DISPATCH_H
  IO *io = (__bridge IO*)s->io;
  [io close];
  s->fd = -1;
  s->last_errno = errno;
#else
  if (ssh_socket_is_open(s)) {
#ifdef _WIN32
    CLOSE_SOCKET(s->fd);
    s->last_errno = WSAGetLastError();
#else
    CLOSE_SOCKET(s->fd);
    s->last_errno = errno;
#endif
  }

  if(s->poll_handle != NULL){
    ssh_poll_free(s->poll_handle);
    s->poll_handle=NULL;
  }
#endif

  s->state = SSH_SOCKET_CLOSED;
}

/**
 * @internal
 * @brief sets the file descriptor of the socket.
 * @param[out] s ssh_socket to update
 * @param[in] fd file descriptor to set
 * @warning this function updates boths the input and output
 * file descriptors
 */
void ssh_socket_set_fd(ssh_socket s, socket_t fd) {
    s->fd = fd;

#ifdef HAVE_DISPATCH_H
    IO *io = (__bridge IO*)s->io;
    s->state = SSH_SOCKET_CONNECTING;
   // [io setupWithFD:fd];
#else

    if (s->poll_handle) {
        ssh_poll_set_fd(s->poll_handle,fd);
    } else {
        s->state = SSH_SOCKET_CONNECTING;

        /* POLLOUT is the event to wait for in a nonblocking connect */
        ssh_poll_set_events(ssh_socket_get_poll_handle(s), POLLOUT);
#ifdef _WIN32
        ssh_poll_add_events(ssh_socket_get_poll_handle(s), POLLWRNORM);
#endif
    }
#endif
}

/** \internal
 * \brief returns the input file descriptor of the socket
 */
socket_t ssh_socket_get_fd(ssh_socket s)
{
  return s->fd;
}

/** \internal
 * \brief returns nonzero if the socket is open
 */
int ssh_socket_is_open(ssh_socket s) {
  return s->fd != SSH_INVALID_SOCKET;
}

#ifndef HAVE_DISPATCH_H

/** \internal
 * \brief read len bytes from socket into buffer
 */
static ssize_t ssh_socket_unbuffered_read(ssh_socket s,
                                          void *buffer,
                                          uint32_t len)
{
    ssize_t rc = -1;

    if (s->data_except) {
        return -1;
    }
    if (s->fd_is_socket) {
        rc = recv(s->fd,buffer, len, 0);
    } else {
        rc = read(s->fd,buffer, len);
    }
#ifdef _WIN32
    s->last_errno = WSAGetLastError();
#else
    s->last_errno = errno;
#endif
    s->read_wontblock = 0;

    if (rc < 0) {
        s->data_except = 1;
    }

    return rc;
}

/** \internal
 * \brief writes len bytes from buffer to socket
 */
static ssize_t ssh_socket_unbuffered_write(ssh_socket s,
                                           const void *buffer,
                                           uint32_t len)
{
    ssize_t w = -1;
    int flags = 0;

#ifdef MSG_NOSIGNAL
    flags |= MSG_NOSIGNAL;
#endif

    if (s->data_except) {
        return -1;
    }

    if (s->fd_is_socket) {
        w = send(s->fd, buffer, len, flags);
    } else {
        w = write(s->fd, buffer, len);
    }
#ifdef _WIN32
    s->last_errno = WSAGetLastError();
#else
    s->last_errno = errno;
#endif
    s->write_wontblock = 0;
    /* Reactive the POLLOUT detector in the poll multiplexer system */
    if (s->poll_handle) {
        SSH_LOG(SSH_LOG_PACKET, "Enabling POLLOUT for socket");
        ssh_poll_set_events(s->poll_handle,ssh_poll_get_events(s->poll_handle) | POLLOUT);
    }
    if (w < 0) {
        s->data_except = 1;
    }

    return w;
}

#endif

/** \internal
 * \brief returns nonzero if the current socket is in the fd_set
 */
int ssh_socket_fd_isset(ssh_socket s, fd_set *set) {
  if(s->fd == SSH_INVALID_SOCKET) {
    return 0;
  }
  return FD_ISSET(s->fd,set);
}

/** \internal
 * \brief sets the current fd in a fd_set and updates the max_fd
 */

void ssh_socket_fd_set(ssh_socket s, fd_set *set, socket_t *max_fd) {
  if (s->fd == SSH_INVALID_SOCKET) {
    return;
  }

  FD_SET(s->fd,set);

  if (s->fd >= 0 &&
      s->fd >= *max_fd &&
      s->fd != SSH_INVALID_SOCKET) {
      *max_fd = s->fd + 1;
  }
}

/** \internal
 * \brief buffered write of data
 * \returns SSH_OK, or SSH_ERROR
 * \warning has no effect on socket before a flush
 */
int ssh_socket_write(ssh_socket s, const void *buffer, int len) {
  if(len > 0) {
    IO *io = (__bridge IO*)s->io;
    [io write:buffer maxLength:len];
  }

  return SSH_OK;
}


/** \internal
 * \brief starts a nonblocking flush of the output buffer
 *
 */
int ssh_socket_nonblocking_flush(ssh_socket s)
{
    ssh_session session = s->session;
    uint32_t len;

    if (!ssh_socket_is_open(s)) {
        session->alive = 0;
        if (s->callbacks && s->callbacks->exception) {
            s->callbacks->exception(SSH_SOCKET_EXCEPTION_ERROR,
                                    s->last_errno,
                                    s->callbacks->userdata);
        } else {
            ssh_set_error(session,
                          SSH_FATAL,
                          "Writing packet: error on socket (or connection "
                          "closed): %s",
                          strerror(s->last_errno));
        }

        return SSH_ERROR;
    }

#ifdef HAVE_DISPATCH_H
  if (s->state != SSH_SOCKET_CONNECTED) {
      return SSH_AGAIN;
  }
  IO *io = (__bridge IO*)s->io;
  [io write:NULL maxLength:0];
  return SSH_OK; // TODO: revisit
#else
    len = ssh_buffer_get_len(s->out_buffer);
    if (!s->write_wontblock && s->poll_handle && len > 0) {
        /* force the poll system to catch pollout events */
        ssh_poll_add_events(s->poll_handle, POLLOUT);
    }

    if (s->write_wontblock && len > 0) {
        ssize_t bwritten;

        bwritten = ssh_socket_unbuffered_write(s,
                                               ssh_buffer_get(s->out_buffer),
                                               len);
        if (bwritten < 0) {
            session->alive = 0;
            ssh_socket_close(s);

            if (s->callbacks && s->callbacks->exception) {
                s->callbacks->exception(SSH_SOCKET_EXCEPTION_ERROR,
                                        s->last_errno,
                                        s->callbacks->userdata);
            } else {
                ssh_set_error(session,
                              SSH_FATAL,
                              "Writing packet: error on socket (or connection "
                              "closed): %s",
                              strerror(s->last_errno));
            }

            return SSH_ERROR;
        }

        ssh_buffer_pass_bytes(s->out_buffer, bwritten);
        if (s->session->socket_counter != NULL) {
            s->session->socket_counter->out_bytes += bwritten;
        }
    }

    /* Is there some data pending? */
    len = ssh_buffer_get_len(s->out_buffer);
    if (s->poll_handle && len > 0) {
        /* force the poll system to catch pollout events */
        ssh_poll_add_events(s->poll_handle, POLLOUT);

        return SSH_AGAIN;
    }
#endif

    /* all data written */
    return SSH_OK;
}

void ssh_socket_set_write_wontblock(ssh_socket s) {
#ifndef HAVE_DISPATCH_H
  s->write_wontblock = 1;
#endif
}

void ssh_socket_set_read_wontblock(ssh_socket s) {
#ifndef HAVE_DISPATCH_H
  s->read_wontblock = 1;
#endif
}

void ssh_socket_set_except(ssh_socket s) {
  s->data_except = 1;
}

int ssh_socket_data_available(ssh_socket s) {
#ifdef HAVE_DISPATCH_H
    return 1;
#else
  return s->read_wontblock;
#endif
}

int ssh_socket_data_writable(ssh_socket s) {
#ifdef HAVE_DISPATCH_H
    return 1;
#else
  return s->write_wontblock;
#endif
}

/** @internal
 * @brief returns the number of outgoing bytes currently buffered
 * @param s the socket
 * @returns numbers of bytes buffered, or 0 if the socket isn't connected
 */
int ssh_socket_buffered_write_bytes(ssh_socket s){
#ifdef HAVE_DISPATCH_H
	if(s==NULL) {
        return 0;
    }
    IO *io = (__bridge IO*)s->io;
    return 0;
    // TODO: revisit
    //return dispatch_data_get_size(io->_out_data);
#else
	if(s==NULL || s->out_buffer == NULL)
		return 0;
	return ssh_buffer_get_len(s->out_buffer);
#endif
}


int ssh_socket_get_status(ssh_socket s) {
  int r = 0;

#ifndef HAVE_DISPATCH_H
  // TODO: fix
  if (ssh_buffer_get_len(s->in_buffer) > 0) {
      r |= SSH_READ_PENDING;
  }

  if (ssh_buffer_get_len(s->out_buffer) > 0) {
      r |= SSH_WRITE_PENDING;
  }
#endif

  if (s->data_except) {
    r |= SSH_CLOSED_ERROR;
  }

  return r;
}

int ssh_socket_get_poll_flags(ssh_socket s) {
  int r = 0;
#ifndef HAVE_DISPATCH_H
  if (s->poll_handle != NULL && (ssh_poll_get_events (s->poll_handle) & POLLIN) > 0) {
    r |= SSH_READ_PENDING;
  }
  if (s->poll_handle != NULL && (ssh_poll_get_events (s->poll_handle) & POLLOUT) > 0) {
    r |= SSH_WRITE_PENDING;
  }
#endif
  return r;
}

#ifdef _WIN32
int ssh_socket_set_nonblocking(socket_t fd) {
  u_long nonblocking = 1;
  return ioctlsocket(fd, FIONBIO, &nonblocking);
}

int ssh_socket_set_blocking(socket_t fd) {
  u_long nonblocking = 0;
  return ioctlsocket(fd, FIONBIO, &nonblocking);
}

#else /* _WIN32 */
int ssh_socket_set_nonblocking(socket_t fd) {
  return fcntl(fd, F_SETFL, O_NONBLOCK);
}

int ssh_socket_set_blocking(socket_t fd) {
  return fcntl(fd, F_SETFL, 0);
}
#endif /* _WIN32 */

/**
 * @internal
 * @brief Launches a socket connection
 * If a the socket connected callback has been defined and
 * a poll object exists, this call will be non blocking.
 * @param s    socket to connect.
 * @param host hostname or ip address to connect to.
 * @param port port number to connect to.
 * @param bind_addr address to bind to, or NULL for default.
 * @returns SSH_OK socket is being connected.
 * @returns SSH_ERROR error while connecting to remote host.
 * @bug It only tries connecting to one of the available AI's
 * which is problematic for hosts having DNS fail-over.
 */

int ssh_socket_connect(ssh_socket s, const char *host, uint16_t port, const char *bind_addr){
	socket_t fd;

	if(s->state != SSH_SOCKET_NONE) {
		ssh_set_error(s->session, SSH_FATAL,
				"ssh_socket_connect called on socket not unconnected");
		return SSH_ERROR;
	}

#ifdef HAVE_DISPATCH_H
    IO *io = (__bridge IO*)s->io;
    return [io connectToHost:@(host) andPort:port];
#else
	fd=ssh_connect_host_nonblocking(s->session,host,bind_addr,port);
	SSH_LOG(SSH_LOG_PROTOCOL,"Nonblocking connection socket: %d",fd);
	if(fd == SSH_INVALID_SOCKET)
		return SSH_ERROR;
	ssh_socket_set_fd(s,fd);
#endif

	return SSH_OK;
}

#ifndef _WIN32
/**
 * @internal
 * @brief executes a command and redirect input and outputs
 * @param command command to execute
 * @param in input file descriptor
 * @param out output file descriptor
 */
void ssh_execute_command(const char *command, socket_t in, socket_t out){
  const char *args[]={"/bin/sh","-c",command,NULL};
  /* redirect in and out to stdin, stdout and stderr */
  dup2(in, 0);
  dup2(out,1);
  dup2(out,2);
  close(in);
  close(out);
  /* BLINK execv(args[0],(char * const *)args); */
  exit(1);
}

/**
 * @internal
 * @brief Open a socket on a ProxyCommand
 * This call will always be nonblocking.
 * @param s    socket to connect.
 * @param command Command to execute.
 * @returns SSH_OK socket is being connected.o
 * @returns SSH_ERROR error while executing the command.
 */

__thread void (*thread_ssh_execute_command)(const char *command, socket_t in, socket_t out) = NULL;

int ssh_socket_connect_proxycommand(ssh_session session, ssh_socket s, const char *command){
  socket_t pair[2];
  int pid;
  int rc;

  if (s->state != SSH_SOCKET_NONE) {
    return SSH_ERROR;
  }

  rc = socketpair(PF_LOCAL, SOCK_STREAM, 0, pair);
  if (rc < 0) {
      return SSH_ERROR;
  }

  SSH_LOG(SSH_LOG_PROTOCOL,"Executing proxycommand '%s'",command);
  if (ssh_callbacks_exists(session->common.callbacks, set_proxycommand_function)) {
    session->common.callbacks->set_proxycommand_function(command, pair[0], pair[0],
                                                         session->common.callbacks->userdata);
  }
  else if (thread_ssh_execute_command != NULL) {
      (*thread_ssh_execute_command)(command, pair[0],pair[0]);
  } else {
    pid = 0; /* BLINK fork(); */
    if(pid == 0){
      ssh_execute_command(command,pair[0],pair[0]);
    }
  }
#ifndef HAVE_DISPATCH_H
  close(pair[0]);
#endif
  SSH_LOG(SSH_LOG_PROTOCOL,"ProxyCommand connection pipe: [%d,%d]",pair[0],pair[1]);
#ifdef HAVE_DISPATCH_H
  IO *io = (__bridge IO*)s->io;
  ssh_socket_set_fd(s, pair[1]);
  s->state=SSH_SOCKET_CONNECTED;
  s->fd_is_socket=0;
  [io connectedWithInFd:pair[1] fdOut:pair[1]];
#else
  ssh_socket_set_fd(s, pair[1]);
  s->state=SSH_SOCKET_CONNECTED;
  s->fd_is_socket=0;
  /* POLLOUT is the event to wait for in a nonblocking connect */
  ssh_poll_set_events(ssh_socket_get_poll_handle(s), POLLIN | POLLOUT);
#endif
  if(s->callbacks && s->callbacks->connected) {
    s->callbacks->connected(SSH_SOCKET_CONNECTED_OK,0,s->callbacks->userdata);
  }

  return SSH_OK;
}

#ifdef HAVE_DISPATCH_H
int ssh_socket_dispatch_wait(ssh_socket s, int milliseconds) {
  IO *io = (__bridge IO*)s->io;
  return [io wait:milliseconds];
}
#endif

#endif /* _WIN32 */
/** @} */
