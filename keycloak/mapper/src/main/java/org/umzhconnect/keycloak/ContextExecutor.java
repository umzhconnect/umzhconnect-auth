package org.umzhconnect.keycloak;

import org.keycloak.representations.idm.ClientPolicyExecutorConfigurationRepresentation;
import org.keycloak.services.clientpolicy.ClientPolicyContext;
import org.keycloak.services.clientpolicy.ClientPolicyEvent;
import org.keycloak.services.clientpolicy.ClientPolicyException;
import org.keycloak.services.clientpolicy.context.ServiceAccountTokenRequestContext;
import org.keycloak.services.clientpolicy.executor.ClientPolicyExecutorProvider;

/**
 * Client policy executor that rejects client_credentials token requests whose
 * authorization_details violate the IG with {@code invalid_authorization_details}
 * (RFC 9396 §5): malformed JSON, an unknown type, a missing identifier, or more
 * than one context.
 *
 * A client policy is used because a protocol mapper cannot fail the request,
 * and Keycloak 26.x does not run its RAR AuthorizationDetailsProcessor SPI for
 * the client_credentials grant.
 */
public class ContextExecutor
        implements ClientPolicyExecutorProvider<ClientPolicyExecutorConfigurationRepresentation> {

    @Override
    public String getProviderId() {
        return ContextExecutorFactory.PROVIDER_ID;
    }

    @Override
    public void executeOnEvent(ClientPolicyContext context) throws ClientPolicyException {
        if (context.getEvent() != ClientPolicyEvent.SERVICE_ACCOUNT_TOKEN_REQUEST) return;

        String raw = ((ServiceAccountTokenRequestContext) context).getParams()
                .getFirst(ContextAuthorizationDetails.PARAM);
        try {
            ContextAuthorizationDetails.parse(raw);
        } catch (ContextAuthorizationDetails.InvalidException e) {
            throw new ClientPolicyException(ContextAuthorizationDetails.ERROR, e.getMessage());
        }
    }
}
