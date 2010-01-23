/*
 * This file is part of the SSH Library
 *
 * Copyright (c) 2009 by Aris Adamantiadis
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

#ifndef PACKET_H_
#define PACKET_H_

/* this structure should go someday */
typedef struct packet_struct {
	int valid;
	uint32_t len;
	uint8_t type;
} PACKET;

/** different state of packet reading. */
enum ssh_packet_state_e {
  /** Packet not initialized, must read the size of packet */
  PACKET_STATE_INIT,
  /** Size was read, waiting for the rest of data */
  PACKET_STATE_SIZEREAD,
  /** Full packet was read and callbacks are being called. Future packets
   * should wait for the end of the callback. */
  PACKET_STATE_PROCESSING
};

int packet_send(ssh_session session);

#ifdef WITH_SSH1
int packet_read(ssh_session session);
int packet_send1(ssh_session session) ;
#endif

int packet_translate(ssh_session session);
/* TODO: remove it when packet_wait is stripped out from libssh */
#ifdef WITH_SSH1
int packet_wait(ssh_session session,int type,int blocking);
#endif
int packet_flush(ssh_session session, int enforce_blocking);


#endif /* PACKET_H_ */
