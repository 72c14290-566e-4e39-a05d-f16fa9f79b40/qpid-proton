/*
 *
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 *
 */
package org.apache.qpid.proton.engine.impl;

import org.apache.qpid.proton.engine.Delivery;
import org.apache.qpid.proton.engine.Sender;
import org.apache.qpid.proton.engine.Sequence;

public class SenderImpl  extends LinkImpl implements Sender
{
    private int _credit;
    private int _offered;
    private TransportSender _transportLink;

    public SenderImpl(SessionImpl session, String name)
    {
        super(session, name);
    }

    public void offer(final int credits)
    {
        _offered = credits;
    }

    public int send(final byte[] bytes, int offset, int length)
    {
        DeliveryImpl current = current();
        if(current == null || current.getLink() != this)
        {
            throw new IllegalArgumentException();//TODO.
        }
        return current.send(bytes, offset, length);
    }

    public void abort()
    {
        //TODO.
    }

    public Sequence<Delivery> unsettled()
    {
        return null;  //TODO.
    }


    public void destroy()
    {
        getSession().destroySender(this);
        super.destroy();

    }

    @Override
    public boolean advance()
    {
        DeliveryImpl delivery = current();
        boolean advance = hasCredit() && super.advance();
        if(advance && _offered > 0)
        {
            _offered--;
            _credit--;
        }
        if(advance)
        {
            delivery.addToTransportWorkList();
        }
        return advance;
    }

    boolean hasCredit()
    {
        return _credit > 0;
    }

    boolean hasOfferedCredits()
    {
        return _offered > 0;
    }

    @Override
    TransportSender getTransportLink()
    {
        return _transportLink;
    }

    void setTransportLink(TransportSender transportLink)
    {
        _transportLink = transportLink;
    }

    public void setCredit(int credit)
    {
        _credit = credit;
    }

    @Override
    boolean workUpdate(DeliveryImpl delivery)
    {
        return (delivery == current()) && hasCredit();
    }
}
