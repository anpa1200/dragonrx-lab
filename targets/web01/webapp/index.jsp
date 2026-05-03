<%@page import="org.apache.logging.log4j.LogManager,org.apache.logging.log4j.Logger"%>
<%@page contentType="application/json; charset=UTF-8"%>
<%
    Logger log = LogManager.getLogger("com.novatech.portal");
    String ver = request.getHeader("X-Api-Version");
    if (ver != null && !ver.isEmpty()) {
        log.info("API Version: " + ver);
        out.print("{\"status\":200,\"service\":\"NovaTech Patient Portal\"}");
    } else {
        response.setStatus(400);
        out.print("{\"timestamp\":" + System.currentTimeMillis() + ",\"status\":400,\"error\":\"Bad Request\",\"path\":\"/\"}");
    }
%>
