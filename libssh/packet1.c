/*
 * This file is part of the SSH Library
 *
 * Copyright (c) 2010 by Aris Adamantiadis
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
#include "libssh/priv.h"
#include "libssh/ssh1.h"
#include "libssh/packet.h"
#include "libssh/session.h"
#include "libssh/buffer.h"
#include "libssh/socket.h"

#ifdef WITH_SSH1
/* a slightly modified packet_read2() for SSH-1 protocol
 * TODO: should be transformed in an asynchronous socket callback
 */
int packet_read(ssh_session session) {
  void *packet = NULL;
  int rc = SSH_ERROR;
  int to_be_read;
  uint32_t padding;
  uint32_t crc;
  uint32_t len;

  enter_function();

  if(!session->alive) {
    goto error;
  }

  switch (session->packet_state){
    case PACKET_STATE_INIT:
      memset(&session->in_packet, 0, sizeof(PACKET));

      if (session->in_buffer) {
        if (buffer_reinit(session->in_buffer) < 0) {
          goto error;
        }
      } else {
        session->in_buffer = buffer_new();
        if (session->in_buffer == NULL) {
          goto error;
        }
      }

      rc = ssh_socket_read(session->socket, &len, sizeof(uint32_t));
      if (rc != SSH_OK) {
        goto error;
      }

      rc = SSH_ERROR;

      /* len is not encrypted */
      len = ntohl(len);
      if (len > MAX_PACKET_LEN) {
        ssh_set_error(session, SSH_FATAL,
            "read_packet(): Packet len too high (%u %.8x)", len, len);
        goto error;
      }

      ssh_log(session, SSH_LOG_PACKET, "Reading a %d bytes packet", len);

      session->in_packet.len = len;
      session->packet_state = PACKET_STATE_SIZEREAD;
    case PACKET_STATE_SIZEREAD:
      len = session->in_packet.len;
      /* SSH-1 has a fixed padding lenght */
      padding = 8 - (len % 8);
      to_be_read = len + padding;

      /* it is _not_ possible that to_be_read be < 8. */
      packet = malloc(to_be_read);
      if (packet == NULL) {
        ssh_set_error(session, SSH_FATAL, "Not enough space");
        goto error;
      }

      rc = ssh_socket_read(session->socket, packet, to_be_read);
      if(rc != SSH_OK) {
        SAFE_FREE(packet);
        goto error;
      }
      rc = SSH_ERROR;

      if (buffer_add_data(session->in_buffer,packet,to_be_read) < 0) {
        SAFE_FREE(packet);
        goto error;
      }
      SAFE_FREE(packet);

#ifdef DEBUG_CRYPTO
      ssh_print_hexa("read packet:", buffer_get(session->in_buffer),
          buffer_get_len(session->in_buffer));
#endif
      if (session->current_crypto) {
        /*
         * We decrypt everything, missing the lenght part (which was
         * previously read, unencrypted, and is not part of the buffer
         */
        if (packet_decrypt(session,
              buffer_get(session->in_buffer),
              buffer_get_len(session->in_buffer)) < 0) {
          ssh_set_error(session, SSH_FATAL, "Packet decrypt error");
          goto error;
        }
      }
#ifdef DEBUG_CRYPTO
      ssh_print_hexa("read packet decrypted:", buffer_get(session->in_buffer),
          buffer_get_len(session->in_buffer));
#endif
      ssh_log(session, SSH_LOG_PACKET, "%d bytes padding", padding);
      if(((len + padding) != buffer_get_rest_len(session->in_buffer)) ||
          ((len + padding) < sizeof(uint32_t))) {
        ssh_log(session, SSH_LOG_RARE, "no crc32 in packet");
        ssh_set_error(session, SSH_FATAL, "no crc32 in packet");
        goto error;
      }

      memcpy(&crc,
          (unsigned char *)buffer_get_rest(session->in_buffer) + (len+padding) - sizeof(uint32_t),
          sizeof(uint32_t));
      buffer_pass_bytes_end(session->in_buffer, sizeof(uint32_t));
      crc = ntohl(crc);
      if (ssh_crc32(buffer_get_rest(session->in_buffer),
            (len + padding) - sizeof(uint32_t)) != crc) {
#ifdef DEBUG_CRYPTO
        ssh_print_hexa("crc32 on",buffer_get_rest(session->in_buffer),
            len + padding - sizeof(uint32_t));
#endif
        ssh_log(session, SSH_LOG_RARE, "Invalid crc32");
        ssh_set_error(session, SSH_FATAL,
            "Invalid crc32: expected %.8x, got %.8x",
            crc,
            ssh_crc32(buffer_get_rest(session->in_buffer),
              len + padding - sizeof(uint32_t)));
        goto error;
      }
      /* pass the padding */
      buffer_pass_bytes(session->in_buffer, padding);
      ssh_log(session, SSH_LOG_PACKET, "The packet is valid");

/* TODO FIXME
#if defined(HAVE_LIBZ) && defined(WITH_LIBZ)
    if(session->current_crypto && session->current_crypto->do_compress_in){
        decompress_buffer(session,session->in_buffer);
    }
#endif
*/
      session->recv_seq++;
      session->packet_state=PACKET_STATE_INIT;

      leave_function();
      return SSH_OK;
  } /* switch */

  ssh_set_error(session, SSH_FATAL,
      "Invalid state into packet_read1(): %d",
      session->packet_state);
error:
  leave_function();
  return rc;
}

#endif /* WITH_SSH1 */
#ifdef WITH_SSH1
int packet_send1(ssh_session session) {
  unsigned int blocksize = (session->current_crypto ?
      session->current_crypto->out_cipher->blocksize : 8);
  uint32_t currentlen = buffer_get_len(session->out_buffer) + sizeof(uint32_t);
  char padstring[32] = {0};
  int rc = SSH_ERROR;
  uint32_t finallen;
  uint32_t crc;
  uint8_t padding;

  enter_function();
  ssh_log(session,SSH_LOG_PACKET,"Sending a %d bytes long packet",currentlen);

/* TODO FIXME
#if defined(HAVE_LIBZ) && defined(WITH_LIBZ)
  if (session->current_crypto && session->current_crypto->do_compress_out) {
    if (compress_buffer(session, session->out_buffer) < 0) {
      goto error;
    }
    currentlen = buffer_get_len(session->out_buffer);
  }
#endif
*/
  padding = blocksize - (currentlen % blocksize);
  if (session->current_crypto) {
    ssh_get_random(padstring, padding, 0);
  } else {
    memset(padstring, 0, padding);
  }

  finallen = htonl(currentlen);
  ssh_log(session, SSH_LOG_PACKET,
      "%d bytes after comp + %d padding bytes = %d bytes packet",
      currentlen, padding, ntohl(finallen));

  if (buffer_prepend_data(session->out_buffer, &padstring, padding) < 0) {
    goto error;
  }
  if (buffer_prepend_data(session->out_buffer, &finallen, sizeof(uint32_t)) < 0) {
    goto error;
  }

  crc = ssh_crc32((char *)buffer_get(session->out_buffer) + sizeof(uint32_t),
      buffer_get_len(session->out_buffer) - sizeof(uint32_t));

  if (buffer_add_u32(session->out_buffer, ntohl(crc)) < 0) {
    goto error;
  }

#ifdef DEBUG_CRYPTO
  ssh_print_hexa("Clear packet", buffer_get(session->out_buffer),
      buffer_get_len(session->out_buffer));
#endif

  packet_encrypt(session, (unsigned char *)buffer_get(session->out_buffer) + sizeof(uint32_t),
      buffer_get_len(session->out_buffer) - sizeof(uint32_t));

#ifdef DEBUG_CRYPTO
  ssh_print_hexa("encrypted packet",buffer_get(session->out_buffer),
      buffer_get_len(session->out_buffer));
#endif
  if (ssh_socket_write(session->socket, buffer_get(session->out_buffer),
      buffer_get_len(session->out_buffer)) == SSH_ERROR) {
    goto error;
  }

  rc = packet_flush(session, 0);
  session->send_seq++;

  if (buffer_reinit(session->out_buffer) < 0) {
    rc = SSH_ERROR;
  }
error:
  leave_function();
  return rc;     /* SSH_OK, AGAIN or ERROR */
}

#endif /* WITH_SSH1 */
#ifdef WITH_SSH1
static void packet_parse(ssh_session session) {
  uint8_t type = session->in_packet.type;

  if (session->version == 1) {
    /* SSH-1 */
    switch(type) {
      case SSH_MSG_DISCONNECT:
        ssh_log(session, SSH_LOG_PACKET, "Received SSH_MSG_DISCONNECT");
        ssh_set_error(session, SSH_FATAL, "Received SSH_MSG_DISCONNECT");

        ssh_socket_close(session->socket);
        session->alive = 0;
        return;
      case SSH_SMSG_STDOUT_DATA:
      case SSH_SMSG_STDERR_DATA:
      case SSH_SMSG_EXITSTATUS:
        channel_handle1(session,type);
        return;
      case SSH_MSG_DEBUG:
      case SSH_MSG_IGNORE:
        break;
      default:
        ssh_log(session, SSH_LOG_PACKET,
            "Unexpected message code %d", type);
    }
    return;
  } else {
  }
}

int packet_wait(ssh_session session, int type, int blocking) {

  enter_function();

  ssh_log(session, SSH_LOG_PROTOCOL, "packet_wait1 waiting for %d", type);

  do {
    if ((packet_read(session) != SSH_OK) ||
        (packet_translate(session) != SSH_OK)) {
      leave_function();
      return SSH_ERROR;
    }
    ssh_log(session, SSH_LOG_PACKET, "packet_wait1() received a type %d packet",
        session->in_packet.type);
    switch (session->in_packet.type) {
      case SSH_MSG_DISCONNECT:
        packet_parse(session);
        leave_function();
        return SSH_ERROR;
      case SSH_SMSG_STDOUT_DATA:
      case SSH_SMSG_STDERR_DATA:
      case SSH_SMSG_EXITSTATUS:
        if (channel_handle1(session,type) < 0) {
          leave_function();
          return SSH_ERROR;
        }
        break;
      case SSH_MSG_DEBUG:
      case SSH_MSG_IGNORE:
        break;
        /*          case SSH2_MSG_CHANNEL_CLOSE:
                    packet_parse(session);
                    break;;
                    */
      default:
        if (type && (type != session->in_packet.type)) {
          ssh_set_error(session, SSH_FATAL,
              "packet_wait1(): Received a %d type packet, but expected %d\n",
              session->in_packet.type, type);
          leave_function();
          return SSH_ERROR;
        }
        leave_function();
        return SSH_OK;
    }

    if (blocking == 0) {
      leave_function();
      return SSH_OK;
    }
  } while(1);

  leave_function();
  return SSH_OK;
}
#endif /* WITH_SSH1 */

/* vim: set ts=2 sw=2 et cindent: */
