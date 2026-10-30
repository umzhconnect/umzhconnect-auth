package org.umzhconnect.keycloak;

import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.rar.AuthorizationDetailsProcessor;
import org.keycloak.protocol.oidc.rar.InvalidAuthorizationDetailsException;
import org.keycloak.representations.AuthorizationDetailsJSONRepresentation;

import java.util.Collections;
import java.util.List;

/**
 * Registers the UMZH context type with Keycloak's RAR machinery.
 *
 * Keycloak 26.x does not run processors for the client_credentials grant —
 * {@link ContextExecutor} validates the request there. It does, however, pass
 * every token-response authorization_details entry (set by {@link ContextMapper})
 * through the processor for its type before sending the response, and fails
 * with a 500 for a type that has no processor.
 */
public class ContextProcessor
        implements AuthorizationDetailsProcessor<AuthorizationDetailsJSONRepresentation> {

    @Override public boolean isSupported()        { return true; }
    @Override public String getSupportedType()    { return ContextAuthorizationDetails.TYPE; }

    @Override
    public Class<AuthorizationDetailsJSONRepresentation> getSupportedResponseJavaType() {
        return AuthorizationDetailsJSONRepresentation.class;
    }

    @Override
    public AuthorizationDetailsJSONRepresentation validateAuthorizationDetail(
            AuthorizationDetailsJSONRepresentation detail) throws InvalidAuthorizationDetailsException {
        String identifier = detail.getIdentifier();
        if (identifier == null || identifier.isBlank()) {
            throw new InvalidAuthorizationDetailsException("context entry is missing identifier");
        }
        AuthorizationDetailsJSONRepresentation normalised = new AuthorizationDetailsJSONRepresentation();
        normalised.setType(ContextAuthorizationDetails.TYPE);
        normalised.setIdentifier(identifier);
        return normalised;
    }

    @Override
    public AuthorizationDetailsJSONRepresentation process(UserSessionModel userSession,
            ClientSessionContext clientSessionCtx, AuthorizationDetailsJSONRepresentation detail)
            throws InvalidAuthorizationDetailsException {
        return validateAuthorizationDetail(detail);
    }

    @Override
    public List<AuthorizationDetailsJSONRepresentation> handleMissingAuthorizationDetails(
            UserSessionModel userSession, ClientSessionContext clientSessionCtx) {
        return Collections.emptyList();
    }

    @Override
    public AuthorizationDetailsJSONRepresentation processStoredAuthorizationDetails(UserSessionModel userSession,
            ClientSessionContext clientSessionCtx, AuthorizationDetailsJSONRepresentation detail)
            throws InvalidAuthorizationDetailsException {
        return validateAuthorizationDetail(detail);
    }

    @Override
    public void afterAuthorizationDetailsProcessed(UserSessionModel userSession,
            ClientSessionContext clientSessionCtx, AuthorizationDetailsJSONRepresentation detail) {}

    @Override public void close() {}
}
